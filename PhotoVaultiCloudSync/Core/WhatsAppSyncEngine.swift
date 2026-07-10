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

    // MARK: - Execução principal

    /// Copia todos os arquivos pendentes de `origemBookmark` para `destinoBookmark`.
    ///
    /// - Returns: número de arquivos efetivamente copiados nesta execução.
    /// - Throws: `SyncError` em caso de falha irrecuperável (ex.: pastas inacessíveis).
    @discardableResult
    func sync(
        origemBookmark: Data,
        destinoBookmark: Data,
        progresso: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int {
        resetarCancelamento()
        await tracker.load()

        let origem = try resolverBookmark(origemBookmark)
        let destino = try resolverBookmark(destinoBookmark)

        guard origem.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { origem.stopAccessingSecurityScopedResource() }

        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        // 1. Enumera a origem e monta a lista de pendentes (ainda não copiados).
        let origemPath = origem.path
        var pendentes: [(url: URL, relativo: String, chave: String)] = []

        for url in enumerarArquivos(em: origem) {
            let caminhoCompleto = url.path
            guard caminhoCompleto.hasPrefix(origemPath) else { continue }
            let relativo = String(caminhoCompleto.dropFirst(origemPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relativo.isEmpty else { continue }

            let tamanho = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let chave = WhatsAppTracker.chave(caminhoRelativo: relativo, tamanho: tamanho)

            let jaFeito = await tracker.isSynced(chave)
            if !jaFeito {
                pendentes.append((url, relativo, chave))
            }
        }

        let total = pendentes.count
        var enviados = 0
        progresso(enviados, total)

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
                progresso(enviados, total)
                continue
            }

            do {
                try copiarComCoordenacao(de: item.url, para: destinoFinal)
                try await tracker.markSynced(item.chave)
            } catch {
                // Um arquivo problemático não aborta os demais — segue para o próximo.
                continue
            }

            enviados += 1
            progresso(enviados, total)
        }

        return enviados
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
