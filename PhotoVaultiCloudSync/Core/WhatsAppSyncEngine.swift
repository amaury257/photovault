//
//  WhatsAppSyncEngine.swift
//  PhotoVaultiCloudSync
//
//  Motor de backup unidirecional de uma pasta ARBITRÁRIA (tipicamente a pasta
//  "Media" do WhatsApp, exposta no app Arquivos) para uma pasta de destino
//  escolhida pelo usuário — funcionalidade SEPARADA do backup de fotos.
//
//  O WhatsApp não expõe a outros apps nenhuma organização por conversa/contato
//  (esses dados ficam no banco interno dele, inacessível por sandbox). Por
//  isso o "filtro" de conteúdo é simplesmente A PASTA que o usuário escolhe
//  como origem: apontar para "WhatsApp Images" copia só imagens; apontar para
//  a pasta "Media" inteira copia tudo.
//
//  Mesma garantia one-way do PhotoSyncEngine: o livro-razão só cresce; nada é
//  removido do destino mesmo que o arquivo de origem seja apagado depois. A
//  origem é SEMPRE só lida (nunca movida/apagada) — não é nossa pasta.
//

import Foundation

actor WhatsAppSyncEngine {

    private let tracker: WhatsAppTracker
    private var cancelado = false

    init(tracker: WhatsAppTracker) {
        self.tracker = tracker
    }

    func cancelar() {
        cancelado = true
    }

    private func resetarCancelamento() {
        cancelado = false
    }

    // MARK: - Resolução de pastas (bookmarks de segurança)

    private func resolverBookmark(_ bookmarkData: Data) throws -> URL {
        var estaDesatualizado = false
        do {
            return try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &estaDesatualizado
            )
        } catch {
            throw SyncError.pastaExternaInacessivel
        }
    }

    // MARK: - Enumeração recursiva da origem

    /// Lista recursivamente todos os arquivos regulares dentro de `raiz`
    /// (ignora pastas e arquivos ocultos).
    private func enumerarArquivos(em raiz: URL) -> [URL] {
        var resultado: [URL] = []
        guard let enumerador = FileManager.default.enumerator(
            at: raiz,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        for case let url as URL in enumerador {
            let valores = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if valores?.isRegularFile == true {
                resultado.append(url)
            }
        }
        return resultado
    }

    /// Deriva um prefixo hexadecimal curto e determinístico a partir de um
    /// texto (mesmo esquema FNV-1a usado no PhotoSyncEngine), para nomear
    /// arquivos de destino sem colisão entre subpastas de origem diferentes.
    private static func prefixoEstavel(para texto: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in texto.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    // MARK: - Informações de armazenamento

    /// Espaço livre (em bytes) no volume da pasta de destino atual.
    func espacoLivreDestino(destinoBookmark: Data) throws -> Int64 {
        let destino = try resolverBookmark(destinoBookmark)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }
        return StorageInfo.espacoLivre(em: destino) ?? 0
    }

    /// Soma o tamanho (em bytes) de todos os arquivos já copiados para a
    /// pasta de destino do WhatsApp. Pode ser lento em pastas grandes.
    func tamanhoTotalBackup(destinoBookmark: Data) throws -> Int64 {
        let destino = try resolverBookmark(destinoBookmark)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }
        return StorageInfo.tamanhoTotal(em: destino)
    }

    // MARK: - Execução principal

    /// Copia todos os arquivos pendentes de TODAS as pastas em `origens` para
    /// `destinoBookmark`.
    ///
    /// - Returns: `ResultadoSync` com a contagem de itens copiados e de falhas.
    ///   Uma falha em UM arquivo não aborta os demais — só erros irrecuperáveis
    ///   (pastas inacessíveis, cancelamento) lançam exceção.
    /// - Throws: `SyncError` em caso de falha irrecuperável (ex.: pastas inacessíveis).
    @discardableResult
    func sync(
        origens: [WhatsAppOrigemBookmark],
        destinoBookmark: Data,
        progresso: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> ResultadoSync {
        resetarCancelamento()
        await tracker.load()

        guard !origens.isEmpty else {
            throw SyncError.pastasNaoConfiguradas
        }

        let origensResolvidas = try origens.map {
            (url: try resolverBookmark($0.bookmark), semNamespace: $0.semNamespace)
        }
        let destino = try resolverBookmark(destinoBookmark)

        // Abre o escopo de segurança de TODAS as origens antes de começar;
        // se qualquer uma falhar, fecha as já abertas e aborta.
        var origensAbertas: [URL] = []
        for (url, _) in origensResolvidas {
            guard url.startAccessingSecurityScopedResource() else {
                for aberta in origensAbertas { aberta.stopAccessingSecurityScopedResource() }
                throw SyncError.pastaExternaInacessivel
            }
            origensAbertas.append(url)
        }
        defer { for aberta in origensAbertas { aberta.stopAccessingSecurityScopedResource() } }

        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        // 1. Enumera TODAS as origens e monta a lista de pendentes (ainda não
        //    copiados). Cada origem contribui com seu próprio "namespace" no
        //    caminho relativo, evitando colisão entre pastas de origem
        //    diferentes que tenham arquivos com o mesmo nome/subcaminho — ver
        //    doc de `WhatsAppOrigemBookmark.semNamespace`.
        var pendentes: [(url: URL, relativo: String, chave: String)] = []

        for (origemURL, semNamespace) in origensResolvidas {
            let origemPath = origemURL.path
            let namespaceOrigem = semNamespace ? nil : Self.prefixoEstavel(para: origemPath)

            for url in enumerarArquivos(em: origemURL) {
                let caminhoCompleto = url.path
                guard caminhoCompleto.hasPrefix(origemPath) else { continue }
                let relativoBruto = String(caminhoCompleto.dropFirst(origemPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !relativoBruto.isEmpty else { continue }

                let relativo = namespaceOrigem.map { "\($0)_\(relativoBruto)" } ?? relativoBruto

                let tamanho = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let chave = WhatsAppTracker.chave(caminhoRelativo: relativo, tamanho: tamanho)

                let jaFeito = await tracker.isSynced(chave)
                if !jaFeito {
                    pendentes.append((url, relativo, chave))
                }
            }
        }

        let total = pendentes.count
        var enviados = 0
        var falhas = 0
        var processados = 0
        progresso(processados, total)

        // 2. Copia cada arquivo pendente.
        for item in pendentes {
            if cancelado { throw SyncError.cancelada }

            let nomeArquivo = (item.relativo as NSString).lastPathComponent
            let prefixo = Self.prefixoEstavel(para: item.relativo)
            let destinoFinal = destino.appendingPathComponent("\(prefixo)_\(nomeArquivo)", isDirectory: false)

            // Idempotência: nunca reescreve/sobrescreve um arquivo já existente.
            if FileManager.default.fileExists(atPath: destinoFinal.path) {
                try await tracker.markSynced(item.chave)
                enviados += 1
                processados += 1
                progresso(processados, total)
                continue
            }

            do {
                try copiarComCoordenacao(de: item.url, para: destinoFinal)
                try await tracker.markSynced(item.chave)
                enviados += 1
            } catch {
                // Um arquivo problemático não aborta os demais — segue para o próximo.
                falhas += 1
            }

            processados += 1
            progresso(processados, total)
        }

        return ResultadoSync(enviados: enviados, falhas: falhas)
    }

    // MARK: - Cópia coordenada (origem: só leitura / destino: escrita)

    /// Copia um arquivo da origem (NUNCA apagado/movido — não é nossa pasta)
    /// para o destino, coordenando leitura e escrita simultaneamente via
    /// `NSFileCoordinator`. Preserva a data de modificação do arquivo de
    /// origem no arquivo final.
    private func copiarComCoordenacao(de origemArquivo: URL, para destinoFinal: URL) throws {
        let coordinator = NSFileCoordinator()
        var erroCoord: NSError?
        var erroInterno: Error?

        coordinator.coordinate(
            readingItemAt: origemArquivo,
            options: [],
            writingItemAt: destinoFinal,
            options: .forReplacing,
            error: &erroCoord
        ) { urlLeitura, urlEscrita in
            do {
                try FileManager.default.copyItem(at: urlLeitura, to: urlEscrita)
                // Preserva a data do arquivo de origem (não a data desta cópia).
                if let dataOriginal = try? urlLeitura.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate {
                    try? FileManager.default.setAttributes(
                        [.creationDate: dataOriginal, .modificationDate: dataOriginal],
                        ofItemAtPath: urlEscrita.path
                    )
                }
            } catch {
                erroInterno = error
            }
        }

        if let erroCoord {
            throw SyncError.escritaFalhou(motivo: erroCoord.localizedDescription)
        }
        if let erroInterno {
            throw SyncError.escritaFalhou(motivo: erroInterno.localizedDescription)
        }
    }
}
