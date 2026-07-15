//
//  PhotoSyncEngine.swift
//  PhotoVaultiCloudSync
//
//  Motor de sincronização. Responsável por:
//    1. Solicitar/validar a permissão de acesso à galeria (PhotoKit).
//    2. Localizar a pasta de destino — uma pasta EXTERNA escolhida pelo usuário
//       via seletor de Arquivos (bookmark de segurança; pode estar no iCloud
//       Drive), ou, na ausência de uma, a pasta local do app (Documents,
//       visível no Arquivos).
//    3. Criar a subpasta local (quando aplicável).
//    4. Iterar os assets, pular os que já estão no livro-razão e exportar as
//       mídias para a pasta de backup usando escrita coordenada (NSFileCoordinator),
//       em um de dois formatos:
//         • ORIGINAL     — dados brutos (HEIC/RAW, vídeo do Live Photo, HEVC).
//         • COMPATÍVEL   — JPEG (fotos) e MP4/H.264 (vídeos), resolução máxima,
//                          para abrir em qualquer PC/Android/navegador.
//
//  Concorrência: implementado como `actor`, então todo o estado interno é
//  acessado de forma serial e thread-safe. As APIs de PhotoKit baseadas em
//  completion handler são adaptadas para async/await via continuations.
//

import Foundation
import Photos
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Motor de backup unidirecional da galeria para a pasta local do app.
actor PhotoSyncEngine {

    /// Livro-razão compartilhado (garante o comportamento one-way e sem duplicatas).
    private let tracker: PhotoTracker

    /// Registro de tamanhos gravados, usado para detectar cópias truncadas
    /// (ver `FileSizeTracker`).
    private let sizeTracker: FileSizeTracker

    /// Sinalização cooperativa de cancelamento (usada pela tarefa em background
    /// quando o tempo expira). Verificada entre os assets.
    private var cancelado = false

    // MARK: - Init

    init(tracker: PhotoTracker, sizeTracker: FileSizeTracker = FileSizeTracker()) {
        self.tracker = tracker
        self.sizeTracker = sizeTracker
    }

    // MARK: - Cancelamento cooperativo

    /// Solicita o cancelamento da sincronização em andamento. O laço principal
    /// verifica esta flag entre assets e encerra de forma limpa.
    func cancelar() {
        cancelado = true
    }

    /// Zera o estado de cancelamento antes de iniciar uma nova execução.
    private func resetarCancelamento() {
        cancelado = false
    }

    // MARK: - Permissão de acesso à galeria

    /// Solicita (ou confirma) a autorização de acesso à biblioteca de fotos.
    ///
    /// Usamos `.readWrite` (o único nível que concede leitura — `PHAccessLevel` não
    /// tem `.readOnly`). Mesmo assim, o app apenas LÊ a galeria, nunca apaga —
    /// coerente com o backup unidirecional.
    ///
    /// - Throws: `SyncError.permissaoNegada` se o usuário não autorizar.
    func requestAuthorization() async throws {
        let atual = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus

        switch atual {
        case .authorized, .limited:
            status = atual
        case .notDetermined:
            // Solicita e aguarda a decisão do usuário de forma assíncrona.
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        default:
            status = atual
        }

        switch status {
        case .authorized, .limited:
            return // `.limited` também serve: fazemos backup do que estiver acessível.
        default:
            throw SyncError.permissaoNegada
        }
    }

    // MARK: - Localização da pasta de backup

    /// Resolve a URL da pasta de destino. Duas origens possíveis:
    ///   1. **Pasta externa escolhida pelo usuário** (via seletor de Arquivos nas
    ///      Configurações — pode estar dentro do iCloud Drive, em outro app de
    ///      nuvem, ou em qualquer local acessível pelo app Arquivos). Persistida
    ///      como um *security-scoped bookmark* em `UserDefaults`.
    ///   2. **Pasta local do próprio app** (`<Documents>/<folderName>/`), usada
    ///      como padrão enquanto nenhuma pasta externa tiver sido escolhida.
    ///      Fica visível no app Arquivos (em "No meu iPhone") porque o
    ///      Info.plist declara `UIFileSharingEnabled` +
    ///      `LSSupportsOpeningDocumentsInPlace`.
    ///
    /// Nenhuma das duas exige conta paga de desenvolvedor: a pasta externa usa o
    /// seletor de arquivos do próprio sistema (não um container de iCloud do
    /// app), e a local funciona com Apple ID gratuito + AltStore.
    ///
    /// - Parameter folderName: nome da subpasta (só usado no caminho local).
    /// - Returns: URL da pasta de destino pronta para gravação.
    /// - Throws: `SyncError.pastaExternaInacessivel` / `.containerNaoEncontrado` / `.escritaFalhou`.
    private func resolverPastaDestino(folderName: String) throws -> URL {
        if let bookmarkData = UserDefaults.standard.data(forKey: SyncConfig.DefaultsKey.destinationBookmark) {
            return try resolverPastaExterna(bookmarkData)
        }
        return try resolverPastaLocal(folderName: folderName)
    }

    /// Resolve uma pasta externa a partir de um bookmark de segurança salvo
    /// anteriormente (criado quando o usuário escolheu a pasta nas Configurações).
    private func resolverPastaExterna(_ bookmarkData: Data) throws -> URL {
        var estaDesatualizado = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &estaDesatualizado
            )
        } catch {
            // Bookmark corrompido, ou a pasta/permissão não existe mais.
            throw SyncError.pastaExternaInacessivel
        }
        // `estaDesatualizado` sinaliza que o bookmark deveria ser regravado,
        // mas a URL resolvida normalmente continua utilizável nesta chamada —
        // não é motivo para falhar a sincronização.
        return url
    }

    /// Resolve (e cria, se necessário) a pasta local padrão dentro de `Documents`.
    private func resolverPastaLocal(folderName: String) throws -> URL {
        let fm = FileManager.default

        // Documents do sandbox do app — é o que aparece no app Arquivos.
        guard let documentos = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw SyncError.containerNaoEncontrado
        }

        // Sanitiza o nome da pasta para evitar caracteres inválidos de caminho.
        let nomeLimpo = Self.sanitizarNomePasta(folderName)
        let destino = documentos.appendingPathComponent(nomeLimpo, isDirectory: true)

        // Cria a subpasta se ainda não existir.
        do {
            try fm.createDirectory(at: destino, withIntermediateDirectories: true)
        } catch {
            throw SyncError.escritaFalhou(motivo: "criar pasta: \(error.localizedDescription)")
        }

        return destino
    }

    // MARK: - Informações de armazenamento

    /// Espaço livre (em bytes) no volume da pasta de destino atual.
    /// - Throws: `SyncError` se a pasta não puder ser resolvida/acessada.
    func espacoLivreDestino(folderName: String) throws -> Int64 {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }
        return StorageInfo.espacoLivre(em: destino) ?? 0
    }

    /// Soma o tamanho (em bytes) de todos os arquivos já copiados para a
    /// pasta de destino. Pode ser lento em pastas grandes (enumera tudo) —
    /// deve ser chamado sob demanda, não automaticamente.
    func tamanhoTotalBackup(folderName: String) throws -> Int64 {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }
        return StorageInfo.tamanhoTotal(em: destino)
    }

    /// Tamanho total ESTIMADO da galeria original (soma dos recursos que um
    /// backup "Original" exportaria — mesmo filtro de `deveExportar`), em
    /// bytes. Diferente de `tamanhoTotalBackup`: este reflete a galeria
    /// inteira, não só o que já foi copiado.
    ///
    /// Usa a chave `"fileSize"` de `PHAssetResource` via KVC — não é uma API
    /// pública documentada, mas é o único jeito de obter o tamanho sem
    /// baixar cada arquivo (o que seria lento e gastaria dados/bateria com
    /// itens ainda só no iCloud). Se a chave parar de responder em alguma
    /// versão futura do iOS, o recurso é simplesmente ignorado no total
    /// (degrada para um número menor, não falha a chamada inteira).
    ///
    /// Pode ser lento em bibliotecas grandes (itera todos os assets) —
    /// chamar sob demanda, nunca automaticamente.
    func tamanhoTotalGaleria(filtro: SyncFiltro = .semFiltro, incluirCompartilhados: Bool = false) -> Int64 {
        buscarAssets(filtro: filtro, incluirCompartilhados: incluirCompartilhados).reduce(into: Int64(0)) { total, asset in
            total += Self.tamanhoEstimado(asset)
        }
    }

    /// Soma o tamanho (em bytes) dos recursos "exportáveis" (mesmo filtro do
    /// backup Original) de um único asset — via a mesma chave `fileSize`
    /// (KVC, não documentada publicamente) usada por `tamanhoTotalGaleria`.
    private static func tamanhoEstimado(_ asset: PHAsset) -> Int64 {
        PHAssetResource.assetResources(for: asset)
            .filter { deveExportar($0.type) }
            .reduce(into: Int64(0)) { total, recurso in
                total += (recurso.value(forKey: "fileSize") as? Int64) ?? 0
            }
    }

    /// Verifica quais itens do livro-razão não têm mais nenhum arquivo
    /// correspondente na pasta de destino atual — indicando que foram
    /// apagados manualmente de lá (por engano, ou para liberar espaço). Não
    /// altera nada, só relata; quem chama decide se quer esquecê-los (ver
    /// `PhotoTracker.removerSelecionados`) para que sejam recopiados.
    ///
    /// Compara pelo PREFIXO estável de 8 caracteres derivado do
    /// `localIdentifier` (não pelo nome completo do arquivo), então funciona
    /// independente do formato de exportação usado quando o item foi
    /// copiado originalmente — que pode ter mudado desde então.
    ///
    /// Pode ser lento em bibliotecas grandes (enumera a pasta inteira) —
    /// chamar sob demanda, nunca automaticamente.
    func verificarConsistencia(folderName: String) async throws -> [String] {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        var prefixosPresentes = Set<String>()
        if let enumerador = FileManager.default.enumerator(
            at: destino,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerador {
                // Só arquivos regulares — uma subpasta com "_" no nome (o
                // usuário pode criar qualquer coisa na pasta pelo Arquivos)
                // não deve ser confundida com o prefixo de um item copiado.
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                let nome = url.lastPathComponent
                if let corte = nome.firstIndex(of: "_") {
                    prefixosPresentes.insert(String(nome[nome.startIndex..<corte]))
                }
            }
        }

        let idsRastreados = await tracker.todosOsIDs
        return idsRastreados.filter { !prefixosPresentes.contains(Self.prefixoEstavel(para: $0)) }
    }

    // MARK: - Livro-razão salvo dentro da pasta de destino (exportar/adotar)

    /// Nome do arquivo OCULTO (prefixo ".") onde uma cópia do livro-razão é
    /// salva dentro da própria pasta de destino — não conta no "Tamanho do
    /// backup" (`StorageInfo.tamanhoTotal` já ignora ocultos) nem confunde a
    /// verificação de consistência (não bate nenhum prefixo de 8 caracteres).
    private static let nomeArquivoLedgerNoDestino = ".iAmaury_ledger.json"

    /// Grava uma cópia do livro-razão (conjunto de `localIdentifier`s já
    /// sincronizados) DENTRO da própria pasta de destino. Permite "adotar"
    /// o backup rapidamente a partir de outra instalação do app — cenário
    /// comum em sideload: reinstalar após a assinatura da AltStore expirar
    /// sem renovar a tempo, ou trocar de aparelho — sem reprocessar a
    /// biblioteca inteira para reconstruir o estado.
    ///
    /// Best-effort por natureza: chamar SEMPRE depois de uma sincronização
    /// já concluída com sucesso, nunca antes; uma falha aqui não deve
    /// comprometer nem repetir o resultado da cópia em si.
    func exportarLedgerParaDestino(folderName: String, tracker: PhotoTracker) async throws {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        let ids = await tracker.todosOsIDs
        let dados = try JSONEncoder().encode(ids)
        let url = destino.appendingPathComponent(Self.nomeArquivoLedgerNoDestino, isDirectory: false)
        try dados.write(to: url, options: [.atomic])
    }

    /// Lê o livro-razão salvo dentro da pasta de destino ATUAL (se houver) e
    /// funde os identificadores nele com o `tracker` informado — só
    /// ACRESCENTA, nunca remove (coerente com o livro-razão "só crescer").
    ///
    /// - Returns: quantos identificadores eram novos. `0` tanto quando não
    ///   há nada de novo quanto quando não existe nenhum ledger salvo ali
    ///   ainda (backup feito antes deste recurso existir, ou pasta nova) —
    ///   não é tratado como erro.
    @discardableResult
    func adotarLedgerDoDestino(folderName: String, tracker: PhotoTracker) async throws -> Int {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        let url = destino.appendingPathComponent(Self.nomeArquivoLedgerNoDestino, isDirectory: false)
        guard let dados = try? Data(contentsOf: url),
              let ids = try? JSONDecoder().decode(Set<String>.self, from: dados) else {
            return 0
        }
        return try await tracker.adotar(ids)
    }

    /// Remove caracteres inválidos e espaços das pontas do nome da pasta,
    /// caindo no nome padrão se o resultado ficar vazio.
    private static func sanitizarNomePasta(_ nome: String) -> String {
        let proibidos = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let limpo = nome
            .components(separatedBy: proibidos)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limpo.isEmpty ? SyncConfig.nomePastaPadrao : limpo
    }

    // MARK: - Busca de assets

    /// Nome da subpasta de destino onde as mídias de **álbuns compartilhados**
    /// são gravadas (separadas das fotos do próprio usuário), quando o usuário
    /// opta por incluí-las. Criada automaticamente dentro da pasta de destino.
    static let subpastaCompartilhados = "Compartilhados"

    /// Busca os assets (fotos e vídeos) que atendem ao `filtro`, ordenados
    /// por data de criação (ascendente — dos mais antigos aos mais novos).
    ///
    /// Sem filtro de álbum: uma única busca na galeria inteira (rápida, via
    /// `PHFetchOptions.predicate` para a data mínima). Com álbuns
    /// selecionados: busca dentro de cada coleção e une os resultados,
    /// descartando duplicatas (um asset pode estar em mais de um álbum
    /// escolhido).
    private func buscarAssets(filtro: SyncFiltro, incluirCompartilhados: Bool = false) -> [PHAsset] {
        let opcoes = PHFetchOptions()
        opcoes.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        // Só fotos e vídeos — descarta áudio e tipos `unknown`, que uma fetch
        // sem filtro traria e inflavam a contagem (ex.: 772 vs 746 da Fototeca).
        // Combinado (AND) com o filtro de data mínima, quando houver.
        var predicados: [NSPredicate] = [
            NSPredicate(format: "mediaType == %d OR mediaType == %d",
                        PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        ]
        if let dataMinima = filtro.dataMinima {
            predicados.append(NSPredicate(format: "creationDate >= %@", dataMinima as NSDate))
        }
        opcoes.predicate = predicados.count == 1
            ? predicados[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicados)

        // Escopo de fontes: por padrão só a biblioteca do próprio usuário (a
        // contagem bate com a Fototeca). `incluirCompartilhados` soma os álbuns
        // compartilhados do iCloud; a sincronização por iTunes fica sempre fora.
        opcoes.includeAssetSourceTypes = incluirCompartilhados
            ? [.typeUserLibrary, .typeCloudShared]
            : [.typeUserLibrary]
        opcoes.includeHiddenAssets = false

        guard !filtro.albunsSelecionados.isEmpty else {
            return Self.paraArray(PHAsset.fetchAssets(with: opcoes))
        }

        let colecoes = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: filtro.albunsSelecionados, options: nil
        )
        var vistos = Set<String>()
        var resultado: [PHAsset] = []
        colecoes.enumerateObjects { colecao, _, _ in
            PHAsset.fetchAssets(in: colecao, options: opcoes).enumerateObjects { asset, _, _ in
                if vistos.insert(asset.localIdentifier).inserted {
                    resultado.append(asset)
                }
            }
        }
        resultado.sort { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
        return resultado
    }

    private static func paraArray(_ resultado: PHFetchResult<PHAsset>) -> [PHAsset] {
        var array: [PHAsset] = []
        array.reserveCapacity(resultado.count)
        resultado.enumerateObjects { asset, _, _ in array.append(asset) }
        return array
    }

    /// Conta o total de itens que atendem ao filtro (fotos + vídeos).
    /// Exposto para o ViewModel atualizar o contador do dashboard.
    func contarAssetsNaGaleria(filtro: SyncFiltro = .semFiltro, incluirCompartilhados: Bool = false) -> Int {
        buscarAssets(filtro: filtro, incluirCompartilhados: incluirCompartilhados).count
    }

    /// Lista os álbuns disponíveis para o filtro de conteúdo: os álbuns
    /// criados pelo usuário e os dois álbuns inteligentes mais relevantes
    /// para excluir do backup (Câmera, como referência do "tudo", e
    /// Screenshots). Omite álbuns vazios. Requer autorização de Fotos já
    /// concedida — chamado só a partir da tela de filtro, que só é
    /// alcançável depois da permissão já ter sido pedida.
    func listarAlbuns() -> [AlbumInfo] {
        var resultado: [AlbumInfo] = []
        func adicionar(_ colecoes: PHFetchResult<PHAssetCollection>) {
            colecoes.enumerateObjects { colecao, _, _ in
                let quantidade = PHAsset.fetchAssets(in: colecao, options: nil).count
                guard quantidade > 0, let titulo = colecao.localizedTitle else { return }
                resultado.append(AlbumInfo(id: colecao.localIdentifier, titulo: titulo, quantidade: quantidade))
            }
        }
        adicionar(PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil))
        adicionar(PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil))
        adicionar(PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil))
        return resultado
    }

    // MARK: - Execução principal

    /// Executa uma passada completa de sincronização.
    ///
    /// - Parameters:
    ///   - folderName: nome da pasta de destino (dentro de Documents do app).
    ///   - formato: `.original` (dados brutos) ou `.compativel` (JPEG/MP4).
    ///   - filtro: quais assets considerar (álbuns/data mínima). Padrão: toda
    ///     a galeria.
    ///   - limiteItemBytesForaDoWifi: quando informado e `emWifi == false`,
    ///     itens maiores que o limite ficam PENDENTES (não contam como
    ///     falha) em vez de consumir dados móveis — tentados de novo numa
    ///     próxima passada, idealmente em Wi-Fi.
    ///   - emWifi: rede atual no momento desta chamada. Irrelevante se
    ///     `limiteItemBytesForaDoWifi` for `nil`.
    ///   - progresso: callback chamado a cada asset PROCESSADO (sucesso ou
    ///     falha) com `(processados, totalPendente)`. Sempre invocado fora do actor.
    /// - Returns: `ResultadoSync` com a contagem de itens copiados e de falhas.
    ///   Uma falha em um item NÃO aborta os demais — só erros irrecuperáveis
    ///   (permissão negada, pasta inacessível, cancelamento) lançam exceção.
    /// - Throws: um `SyncError` em caso de falha irrecuperável (pré-condições).
    @discardableResult
    func sync(
        folderName: String,
        formato: ExportFormat = SyncConfig.formatoPadrao,
        filtro: SyncFiltro = .semFiltro,
        incluirCompartilhados: Bool = false,
        limiteItemBytesForaDoWifi: Int64? = nil,
        emWifi: Bool = true,
        progresso: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> ResultadoSync {
        resetarCancelamento()

        // 1. Garantias de pré-condição (permissão + pasta) antes de qualquer I/O.
        try await requestAuthorization()
        await tracker.load()
        let destino = try resolverPastaDestino(folderName: folderName)

        // Mantém o acesso à pasta de destino "aberto" durante toda a sincronização.
        // Necessário para pastas externas escolhidas via seletor de Arquivos
        // (bookmark de segurança); em uma pasta local do próprio app, esta chamada
        // é inofensiva (retorna true sem efeito — não há escopo de segurança a
        // iniciar). Ver: https://developer.apple.com/documentation/foundation/nsurl/1417051-startaccessingsecurityscopedresource
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        // Subpasta dos compartilhados criada de forma preguiçosa (só quando o
        // primeiro asset compartilhado for gravado) — evita criar pasta vazia.
        let destinoCompartilhados = destino.appendingPathComponent(
            Self.subpastaCompartilhados, isDirectory: true)
        var subpastaCompartilhadosCriada = false

        // 2. Levanta os assets (já filtrados) e calcula quantos ainda estão
        //    pendentes, para que a barra de progresso reflita apenas o
        //    trabalho real desta execução.
        let assets = buscarAssets(filtro: filtro, incluirCompartilhados: incluirCompartilhados)
        var pendentes: [PHAsset] = []
        pendentes.reserveCapacity(assets.count)

        for asset in assets {
            let jaFeito = await tracker.isSynced(asset.localIdentifier)
            if !jaFeito {
                pendentes.append(asset)
            }
        }

        let total = pendentes.count
        var enviados = 0
        var falhas = 0
        var processados = 0
        var caminhosRelativosCopiados: [String] = []
        progresso(processados, total)

        // 3. Exporta cada asset pendente. Uma falha em UM asset (ex.: foto
        //    corrompida, download do iCloud falhou) não pode travar o backup
        //    inteiro — registramos a falha e seguimos para o próximo.
        for asset in pendentes {
            // Cancelamento cooperativo (ex.: expiração da BG task).
            if cancelado { throw SyncError.cancelada }

            // Limite de tamanho por item fora do Wi-Fi: item grande demais
            // fica PENDENTE (não é falha) até uma passada em Wi-Fi.
            if !emWifi, let limite = limiteItemBytesForaDoWifi,
               Self.tamanhoEstimado(asset) > limite {
                processados += 1
                progresso(processados, total)
                continue
            }

            // Assets de álbum compartilhado vão para a subpasta "Compartilhados";
            // os demais, direto na raiz do destino.
            let ehCompartilhado = asset.sourceType.contains(.typeCloudShared)
            let destinoAsset = ehCompartilhado ? destinoCompartilhados : destino
            let prefixoRelativo = ehCompartilhado ? "\(Self.subpastaCompartilhados)/" : ""

            do {
                // Cria a subpasta de compartilhados sob demanda, na primeira vez.
                if ehCompartilhado && !subpastaCompartilhadosCriada {
                    try FileManager.default.createDirectory(
                        at: destinoCompartilhados, withIntermediateDirectories: true)
                    subpastaCompartilhadosCriada = true
                }

                let nomes = try await exportarAsset(asset, para: destinoAsset, formato: formato)
                // Só marca no livro-razão APÓS a escrita coordenada bem-sucedida.
                try await tracker.markSynced(asset.localIdentifier)
                enviados += 1
                // Prefixa com "Compartilhados/" para a verificação de upload no
                // iCloud resolver o caminho correto dentro do destino.
                caminhosRelativosCopiados.append(contentsOf: nomes.map { prefixoRelativo + $0 })
            } catch {
                falhas += 1
            }

            processados += 1
            progresso(processados, total)
        }

        return ResultadoSync(
            enviados: enviados, falhas: falhas,
            caminhosRelativosCopiados: caminhosRelativosCopiados
        )
    }

    // MARK: - Verificação de integridade (arquivos já existentes no destino)

    /// Tamanho atual (em bytes) de um arquivo no disco, ou `nil` se não
    /// existir ou não puder ser lido.
    private func tamanhoEmDisco(_ url: URL) -> Int64? {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: url.path),
              let tamanho = atributos[.size] as? NSNumber else {
            return nil
        }
        return tamanho.int64Value
    }

    /// Decide se um arquivo já existente no destino pode ser tratado como
    /// cópia válida (o motor pula a reexportação): existe E o tamanho bate
    /// com o registrado na última escrita bem-sucedida (`FileSizeTracker`).
    ///
    /// Sem registro anterior — caso de backups feitos antes deste recurso
    /// existir — confia na simples existência, como sempre foi: evita forçar
    /// uma reexportação em massa da biblioteca inteira só por causa desta
    /// atualização do app. Aproveita para registrar o tamanho ATUAL agora
    /// (best-effort) — assim esses arquivos "legados" passam a se beneficiar
    /// da detecção de truncamento a partir da PRÓXIMA sincronização, em vez
    /// de nunca ganharem um registro.
    private func copiaValida(em destinoFinal: URL, nomeArquivo: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: destinoFinal.path) else { return false }
        guard let esperado = await sizeTracker.esperado(paraArquivo: nomeArquivo) else {
            if let atual = tamanhoEmDisco(destinoFinal) {
                await sizeTracker.registrar(arquivo: nomeArquivo, tamanho: atual)
            }
            return true
        }
        return tamanhoEmDisco(destinoFinal) == esperado
    }

    /// Remove um arquivo inválido/truncado antes de regravá-lo, e esquece
    /// seu registro de tamanho (será regravado após a nova escrita).
    private func removerCopiaInvalida(em destinoFinal: URL, nomeArquivo: String) async {
        try? FileManager.default.removeItem(at: destinoFinal)
        await sizeTracker.esquecer(arquivo: nomeArquivo)
    }

    // MARK: - Exportação de um asset (dispatcher por formato)

    /// Ponto único de exportação de um asset. Encaminha para o caminho de dados
    /// brutos (`.original`) ou para o caminho de conversão universal (`.compativel`).
    ///
    /// - Returns: os nomes de arquivo (relativos à pasta de destino) gravados
    ///   ou já existentes para este asset — usados na verificação de upload.
    @discardableResult
    private func exportarAsset(
        _ asset: PHAsset,
        para destino: URL,
        formato: ExportFormat
    ) async throws -> [String] {
        switch formato {
        case .original:
            return try await exportarRecursosOriginais(asset, para: destino)
        case .compativel:
            return try await exportarCompativel(asset, para: destino)
        }
    }

    // MARK: - Modo ORIGINAL (dados brutos)

    /// Exporta TODOS os recursos originais de um asset para a pasta de destino.
    ///
    /// Um único asset pode ter vários `PHAssetResource`:
    ///   - foto original (.photo) + eventual RAW pareado (.alternatePhoto);
    ///   - vídeo original (.video);
    ///   - o vídeo de um Live Photo (.pairedVideo).
    /// Exportamos todos para um backup "original completo".
    @discardableResult
    private func exportarRecursosOriginais(_ asset: PHAsset, para destino: URL) async throws -> [String] {
        let recursos = PHAssetResource.assetResources(for: asset)
        guard !recursos.isEmpty else {
            // Sem recursos acessíveis (asset degradado). Não é fatal para os demais,
            // mas sinalizamos para que o chamador registre o problema.
            throw SyncError.recursoIndisponivel(nomeArquivo: asset.localIdentifier)
        }

        // Prefixo curto e estável derivado do localIdentifier, para evitar colisões
        // entre arquivos de mesmo nome originados de assets diferentes.
        let prefixo = Self.prefixoEstavel(para: asset.localIdentifier)
        var nomesGravados: [String] = []

        for recurso in recursos {
            guard Self.deveExportar(recurso.type) else { continue }

            let nomeArquivo = "\(prefixo)_\(recurso.originalFilename)"
            let destinoFinal = destino.appendingPathComponent(nomeArquivo, isDirectory: false)

            // Idempotência: se o arquivo já existe no destino E o tamanho bate com
            // o que foi gravado da última vez, não reescreve — reforça o one-way
            // (nunca sobrescrevemos/removemos cópias VÁLIDAS existentes). Um
            // tamanho divergente indica cópia truncada (queda de energia, app
            // encerrado no meio da escrita) — nesse caso, remove e regrava.
            if await copiaValida(em: destinoFinal, nomeArquivo: nomeArquivo) {
                nomesGravados.append(nomeArquivo)
                continue
            }
            await removerCopiaInvalida(em: destinoFinal, nomeArquivo: nomeArquivo)

            // 3a. Escreve os dados originais em um arquivo TEMPORÁRIO local.
            //     writeData(for:toFile:) faz streaming para disco — não carrega
            //     vídeos inteiros em memória.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + nomeArquivo)

            try await escreverRecursoEmArquivo(recurso, tempURL: tempURL)

            // 3b. Move o arquivo temporário para a pasta de destino (escrita coordenada),
            //     preservando a data original da foto/vídeo (não a data do backup).
            try coordenarMovimento(de: tempURL, para: destinoFinal, dataOriginal: asset.creationDate)
            if let tamanhoFinal = tamanhoEmDisco(destinoFinal) {
                await sizeTracker.registrar(arquivo: nomeArquivo, tamanho: tamanhoFinal)
            }
            nomesGravados.append(nomeArquivo)
        }

        return nomesGravados
    }

    /// Decide quais tipos de recurso entram no backup "original completo".
    private static func deveExportar(_ tipo: PHAssetResourceType) -> Bool {
        switch tipo {
        case .photo, .video, .pairedVideo, .fullSizePhoto, .fullSizeVideo, .alternatePhoto:
            return true
        default:
            // Ignora recursos auxiliares (ex.: ajustes/adjustmentData).
            return false
        }
    }

    /// Deriva um prefixo hexadecimal curto (8 chars) e determinístico a partir
    /// do `localIdentifier`, para nomear arquivos sem colisão.
    private static func prefixoEstavel(para localIdentifier: String) -> String {
        // `hashValue` varia entre execuções; usamos uma soma FNV-1a simples e
        // estável para gerar sempre o mesmo prefixo para o mesmo identifier.
        var hash: UInt32 = 2_166_136_261
        for byte in localIdentifier.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    // MARK: - Modo COMPATÍVEL (JPEG / MP4 H.264, resolução máxima)

    /// Exporta um asset em formato universal, preservando a resolução máxima:
    ///   - Fotos (inclusive HEIC/RAW e o quadro-chave de Live Photos) → JPEG.
    ///   - Vídeos → MP4 com codec H.264 (transcodifica de HEVC quando necessário).
    @discardableResult
    private func exportarCompativel(_ asset: PHAsset, para destino: URL) async throws -> [String] {
        let prefixo = Self.prefixoEstavel(para: asset.localIdentifier)
        let base = Self.nomeBase(para: asset)

        switch asset.mediaType {
        case .image:
            let nomeArquivo = "\(prefixo)_\(base).jpg"
            let destinoFinal = destino.appendingPathComponent(nomeArquivo, isDirectory: false)
            // Idempotência: nunca reescreve cópia VÁLIDA existente (one-way). Um
            // tamanho divergente do registrado indica truncamento — regrava.
            if await copiaValida(em: destinoFinal, nomeArquivo: nomeArquivo) { return [nomeArquivo] }
            await removerCopiaInvalida(em: destinoFinal, nomeArquivo: nomeArquivo)

            let jpeg = try await obterJPEGCompativel(asset)
            try gravarDados(jpeg, em: destinoFinal, nomeTemp: "\(base).jpg", dataOriginal: asset.creationDate)
            if let tamanhoFinal = tamanhoEmDisco(destinoFinal) {
                await sizeTracker.registrar(arquivo: nomeArquivo, tamanho: tamanhoFinal)
            }
            return [nomeArquivo]

        case .video:
            let nomeArquivo = "\(prefixo)_\(base).mp4"
            let destinoFinal = destino.appendingPathComponent(nomeArquivo, isDirectory: false)
            if await copiaValida(em: destinoFinal, nomeArquivo: nomeArquivo) { return [nomeArquivo] }
            await removerCopiaInvalida(em: destinoFinal, nomeArquivo: nomeArquivo)

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + base + ".mp4")
            try await exportarVideoH264(asset, paraArquivo: tempURL)
            try coordenarMovimento(de: tempURL, para: destinoFinal, dataOriginal: asset.creationDate)
            if let tamanhoFinal = tamanhoEmDisco(destinoFinal) {
                await sizeTracker.registrar(arquivo: nomeArquivo, tamanho: tamanhoFinal)
            }
            return [nomeArquivo]

        default:
            // Áudio ou tipos desconhecidos: nada a exportar no modo compatível.
            return []
        }
    }

    /// Obtém os dados da foto em resolução máxima e devolve JPEG universal.
    ///
    /// Se o original já for JPEG, os bytes são repassados sem reencode (qualidade
    /// intacta). Caso contrário (HEIC/RAW/PNG…), transcodifica para JPEG via ImageIO,
    /// preservando EXIF, GPS e orientação.
    private func obterJPEGCompativel(_ asset: PHAsset) async throws -> Data {
        let opcoes = PHImageRequestOptions()
        opcoes.isNetworkAccessAllowed = true          // baixa do iCloud se preciso
        opcoes.deliveryMode = .highQualityFormat      // sempre a melhor versão
        opcoes.resizeMode = .none                     // resolução original, sem redução
        opcoes.version = .current                     // inclui edições aplicadas
        opcoes.isSynchronous = false

        let (dados, uti): (Data, String?) = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: opcoes
            ) { data, dataUTI, _, info in
                if let data {
                    cont.resume(returning: (data, dataUTI))
                } else {
                    let erro = (info?[PHImageErrorKey] as? Error)
                    cont.resume(throwing: erro
                        ?? SyncError.recursoIndisponivel(nomeArquivo: asset.localIdentifier))
                }
            }
        }

        // Já é JPEG? Repassa sem reencode.
        if uti == UTType.jpeg.identifier {
            return dados
        }

        // Transcodifica preservando metadados e resolução.
        guard let jpeg = Self.transcodificarParaJPEG(dados, qualidade: SyncConfig.jpegQualidade) else {
            throw SyncError.escritaFalhou(motivo: "falha ao converter foto para JPEG")
        }
        return jpeg
    }

    /// Converte quaisquer dados de imagem (HEIC/RAW/PNG…) para JPEG via ImageIO.
    ///
    /// Usa `CGImageDestinationAddImageFromSource`, que copia a imagem em resolução
    /// plena JUNTO com seus metadados (EXIF/GPS/orientação), aplicando apenas a
    /// qualidade de compressão JPEG informada.
    private static func transcodificarParaJPEG(_ dados: Data, qualidade: Double) -> Data? {
        guard let fonte = CGImageSourceCreateWithData(dados as CFData, nil),
              CGImageSourceGetCount(fonte) > 0 else {
            return nil
        }
        let saida = NSMutableData()
        guard let destino = CGImageDestinationCreateWithData(
            saida as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: qualidade]
        CGImageDestinationAddImageFromSource(destino, fonte, 0, props as CFDictionary)
        guard CGImageDestinationFinalize(destino) else { return nil }
        return saida as Data
    }

    /// Exporta um vídeo para MP4/H.264 em resolução máxima (até 4K) usando
    /// `AVAssetExportSession`. Prefere presets H.264 para garantir reprodução
    /// universal; recai em "HighestQuality" apenas se nenhum preset H.264 servir.
    private func exportarVideoH264(_ asset: PHAsset, paraArquivo tempURL: URL) async throws {
        // 1. Obtém o AVAsset (baixando do iCloud se necessário).
        let opcoes = PHVideoRequestOptions()
        opcoes.isNetworkAccessAllowed = true
        opcoes.deliveryMode = .highQualityFormat
        opcoes.version = .current

        let avAsset: AVAsset = try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: opcoes
            ) { avAsset, _, info in
                if let avAsset {
                    cont.resume(returning: avAsset)
                } else {
                    let erro = (info?[PHImageErrorKey] as? Error)
                    cont.resume(throwing: erro
                        ?? SyncError.recursoIndisponivel(nomeArquivo: asset.localIdentifier))
                }
            }
        }

        // 2. Escolhe o melhor preset H.264 compatível com este vídeo. Os presets
        //    de dimensão (…3840x2160, …1920x1080) produzem H.264 e apenas reduzem
        //    a resolução se o vídeo for maior — preservando a qualidade original.
        let preferidos = [
            AVAssetExportPreset3840x2160,
            AVAssetExportPreset1920x1080,
            AVAssetExportPresetHighestQuality,
        ]
        let compativeis = AVAssetExportSession.exportPresets(compatibleWith: avAsset)
        let preset = preferidos.first(where: { compativeis.contains($0) })
            ?? AVAssetExportPresetHighestQuality

        guard let sessao = AVAssetExportSession(asset: avAsset, presetName: preset) else {
            throw SyncError.escritaFalhou(motivo: "não foi possível criar a sessão de exportação de vídeo")
        }
        sessao.outputURL = tempURL
        sessao.outputFileType = .mp4                 // container universal (.mp4)
        sessao.shouldOptimizeForNetworkUse = true
        // AVAssetExportSession NÃO copia metadados automaticamente — sem isto, o
        // .mp4 exportado perde a data de criação embutida no container (distinto
        // da data do ARQUIVO, que é ajustada depois via coordenarMovimento).
        sessao.metadata = avAsset.metadata

        // 3. Exporta de forma assíncrona (API compatível com iOS 16+).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessao.exportAsynchronously {
                switch sessao.status {
                case .completed:
                    cont.resume()
                case .cancelled:
                    cont.resume(throwing: SyncError.cancelada)
                default:
                    let motivo = sessao.error?.localizedDescription ?? "exportação de vídeo falhou"
                    // Detecta disco cheio também durante a exportação.
                    if let ns = sessao.error as NSError?,
                       ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError {
                        cont.resume(throwing: SyncError.armazenamentoCheio)
                    } else {
                        cont.resume(throwing: SyncError.escritaFalhou(motivo: motivo))
                    }
                }
            }
        }
    }

    /// Grava um bloco de `Data` no destino final com escrita coordenada
    /// (reutiliza `coordenarMovimento` a partir de um arquivo temporário).
    private func gravarDados(_ dados: Data, em destinoFinal: URL, nomeTemp: String, dataOriginal: Date?) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + nomeTemp)
        do {
            try dados.write(to: tempURL, options: [.atomic])
        } catch {
            throw Self.mapearErroDeEscrita(error, nomeArquivo: destinoFinal.lastPathComponent)
        }
        try coordenarMovimento(de: tempURL, para: destinoFinal, dataOriginal: dataOriginal)
    }

    /// Deriva o nome-base (sem extensão) de um asset a partir do nome de arquivo
    /// original do seu recurso principal. Recai em um nome estável se indisponível.
    private static func nomeBase(para asset: PHAsset) -> String {
        let recursos = PHAssetResource.assetResources(for: asset)
        let principal = recursos.first(where: { $0.type == .photo || $0.type == .video })
            ?? recursos.first
        if let nome = principal?.originalFilename {
            let semExt = (nome as NSString).deletingPathExtension
            if !semExt.isEmpty { return semExt }
        }
        return "PhotoVault_\(prefixoEstavel(para: asset.localIdentifier))"
    }

    // MARK: - Pontes async para APIs de completion handler

    /// Escreve os dados de um `PHAssetResource` em um arquivo local, permitindo
    /// baixar o original do iCloud Photos se necessário.
    private func escreverRecursoEmArquivo(
        _ recurso: PHAssetResource,
        tempURL: URL
    ) async throws {
        let opcoes = PHAssetResourceRequestOptions()
        // Permite baixar do iCloud originais que não estão no dispositivo.
        opcoes.isNetworkAccessAllowed = true

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: recurso,
                    toFile: tempURL,
                    options: opcoes
                ) { erro in
                    if let erro {
                        cont.resume(throwing: erro)
                    } else {
                        cont.resume()
                    }
                }
            }
        } catch {
            throw Self.mapearErroDeEscrita(error, nomeArquivo: recurso.originalFilename)
        }
    }

    /// Move um arquivo para o destino usando `NSFileCoordinator`,
    /// garantindo uma escrita coordenada e thread-safe da pasta de backup.
    ///
    /// - Parameter dataOriginal: data de criação da FOTO/VÍDEO (`PHAsset.creationDate`),
    ///   aplicada ao arquivo final para que ele fique com a data em que a mídia foi
    ///   tirada — não com a data em que o backup foi executado. Sem isso, o arquivo
    ///   herda a data "agora" do momento da gravação em disco (comportamento padrão
    ///   do sistema de arquivos).
    private func coordenarMovimento(de origem: URL, para destinoFinal: URL, dataOriginal: Date?) throws {
        let coordinator = NSFileCoordinator()
        var erroCoord: NSError?
        var erroInterno: Error?

        // `.forMoving` prepara o coordenador para uma operação de movimentação.
        coordinator.coordinate(
            writingItemAt: destinoFinal,
            options: .forReplacing,
            error: &erroCoord
        ) { urlCoordenada in
            do {
                let fm = FileManager.default
                // Move o temporário para a pasta de destino. Se algo já existir,
                // já teríamos retornado antes (checagem de existência).
                try fm.moveItem(at: origem, to: urlCoordenada)
                // Aplica a data original da mídia (best-effort: se falhar, o backup
                // do arquivo em si já foi concluído com sucesso, então não abortamos).
                if let dataOriginal {
                    try? fm.setAttributes(
                        [.creationDate: dataOriginal, .modificationDate: dataOriginal],
                        ofItemAtPath: urlCoordenada.path
                    )
                }
            } catch {
                erroInterno = error
            }
        }

        // Limpa o temporário caso o move não tenha ocorrido.
        try? FileManager.default.removeItem(at: origem)

        if let erroCoord {
            throw Self.mapearErroDeEscrita(erroCoord, nomeArquivo: destinoFinal.lastPathComponent)
        }
        if let erroInterno {
            throw Self.mapearErroDeEscrita(erroInterno, nomeArquivo: destinoFinal.lastPathComponent)
        }
    }

    // MARK: - Verificação de upload no iCloud

    /// `true` quando a pasta de destino ATUAL está dentro do iCloud Drive (ou
    /// outro provedor "ubíquo" do Files) — só nesse caso existe um "upload"
    /// real para confirmar. Pasta local do app sempre retorna `false`.
    func destinoEhICloud(folderName: String) throws -> Bool {
        let destino = try resolverPastaDestino(folderName: folderName)
        return FileManager.default.isUbiquitousItem(at: destino)
    }

    /// Verifica, por polling limitado no tempo, se os arquivos em
    /// `caminhosRelativos` (relativos à pasta de destino) já terminaram de
    /// subir para o iCloud.
    ///
    /// Usa as chaves padrão de `URLResourceValues` para itens ubíquos —
    /// disponíveis para qualquer URL dentro de um container do iCloud Drive ao
    /// qual o app tenha acesso (via bookmark do seletor de Arquivos), sem
    /// exigir nenhum entitlement de iCloud próprio do app.
    ///
    /// Não usamos `NSMetadataQuery` (a API "correta" orientada a eventos) de
    /// propósito: este app só roda em primeiro plano durante uma checagem
    /// pontual, então um polling simples e com prazo é mais fácil de raciocinar
    /// e não deixa observadores pendurados entre execuções.
    ///
    /// - Returns: os caminhos confirmados, os ainda pendentes (não deram tempo
    ///   de confirmar dentro do prazo) e os que retornaram erro de upload.
    func verificarUploads(
        folderName: String,
        caminhosRelativos: [String],
        timeout: TimeInterval = 45,
        intervaloPollNanos: UInt64 = 1_500_000_000,
        progresso: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> (confirmados: [String], pendentes: [String], comErro: [(caminho: String, mensagem: String)]) {
        let destino = try resolverPastaDestino(folderName: folderName)
        guard destino.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { destino.stopAccessingSecurityScopedResource() }

        var restantes = caminhosRelativos
        var confirmados: [String] = []
        var comErro: [(caminho: String, mensagem: String)] = []
        let total = caminhosRelativos.count
        let prazo = Date().addingTimeInterval(timeout)

        // `repeat` garante sempre UMA passada, mesmo com `timeout` de 0 —
        // usado pelas checagens rápidas (ex.: ao abrir a tela), que só querem
        // o status atual sem ficar esperando uploads em andamento terminarem.
        repeat {
            var aindaPendentes: [String] = []
            for caminho in restantes {
                let url = destino.appendingPathComponent(caminho, isDirectory: false)
                let valores = try? url.resourceValues(forKeys: [
                    .ubiquitousItemIsUploadedKey,
                    .ubiquitousItemUploadingErrorKey,
                ])
                if let erro = valores?.ubiquitousItemUploadingError {
                    comErro.append((caminho, erro.localizedDescription))
                } else if valores?.ubiquitousItemIsUploaded == true {
                    confirmados.append(caminho)
                } else {
                    aindaPendentes.append(caminho)
                }
            }
            restantes = aindaPendentes
            progresso(total - restantes.count, total)

            guard !restantes.isEmpty, Date() < prazo else { break }
            try? await Task.sleep(nanoseconds: intervaloPollNanos)
        } while true

        return (confirmados, restantes, comErro)
    }

    /// Traduz erros de I/O em `SyncError` amigáveis, detectando o caso de
    /// armazenamento cheio (dispositivo).
    private static func mapearErroDeEscrita(_ erro: Error, nomeArquivo: String) -> SyncError {
        let ns = erro as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return .armazenamentoCheio
        }
        // Erro de rede/iCloud indisponível durante o download do recurso.
        if ns.domain == NSURLErrorDomain {
            return .recursoIndisponivel(nomeArquivo: nomeArquivo)
        }
        return .escritaFalhou(motivo: erro.localizedDescription)
    }
}
