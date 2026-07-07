//
//  PhotoSyncEngine.swift
//  PhotoVaultiCloudSync
//
//  Motor de sincronização. Responsável por:
//    1. Solicitar/validar a permissão de acesso à galeria (PhotoKit).
//    2. Localizar a pasta de backup local (Documents do app, visível no Arquivos).
//    3. Criar a subpasta de destino escolhida pelo usuário.
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

    /// Sinalização cooperativa de cancelamento (usada pela tarefa em background
    /// quando o tempo expira). Verificada entre os assets.
    private var cancelado = false

    // MARK: - Init

    init(tracker: PhotoTracker) {
        self.tracker = tracker
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

    /// Solicita (ou confirma) a autorização de leitura da biblioteca de fotos.
    ///
    /// Usamos `.readOnly`: o app apenas LÊ a galeria, nunca modifica/apaga —
    /// coerente com o backup unidirecional e com menor fricção de permissão.
    ///
    /// - Throws: `SyncError.permissaoNegada` se o usuário não autorizar.
    func requestAuthorization() async throws {
        let atual = PHPhotoLibrary.authorizationStatus(for: .readOnly)
        let status: PHAuthorizationStatus

        switch atual {
        case .authorized, .limited:
            status = atual
        case .notDetermined:
            // Solicita e aguarda a decisão do usuário de forma assíncrona.
            status = await PHPhotoLibrary.requestAuthorization(for: .readOnly)
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

    // MARK: - Localização da pasta de backup (local, app Arquivos)

    /// Resolve a URL da pasta de destino dentro do diretório `Documents` do app,
    /// criando-a se necessário. O caminho é `<Documents>/<folderName>/`.
    ///
    /// Essa pasta fica **visível e navegável no app Arquivos** (em "No meu iPhone"
    /// ▸ PhotoVault) porque o Info.plist declara `UIFileSharingEnabled` e
    /// `LSSupportsOpeningDocumentsInPlace`. Não exige iCloud nem conta paga de
    /// desenvolvedor — funciona com Apple ID gratuito + AltStore.
    ///
    /// - Parameter folderName: nome da subpasta escolhido pelo usuário.
    /// - Returns: URL da pasta de destino pronta para gravação.
    /// - Throws: `SyncError.containerNaoEncontrado` / `.escritaFalhou`.
    private func resolverPastaDestino(folderName: String) throws -> URL {
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

    /// Busca todos os assets (fotos e vídeos) ordenados por data de criação
    /// (ascendente — dos mais antigos aos mais novos).
    private func buscarAssets() -> PHFetchResult<PHAsset> {
        let opcoes = PHFetchOptions()
        opcoes.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        // Não filtramos por mediaType: queremos imagens E vídeos.
        return PHAsset.fetchAssets(with: opcoes)
    }

    /// Conta o total de itens atualmente na galeria (fotos + vídeos).
    /// Exposto para o ViewModel atualizar o contador do dashboard.
    func contarAssetsNaGaleria() -> Int {
        buscarAssets().count
    }

    // MARK: - Execução principal

    /// Executa uma passada completa de sincronização.
    ///
    /// - Parameters:
    ///   - folderName: nome da pasta de destino (dentro de Documents do app).
    ///   - formato: `.original` (dados brutos) ou `.compativel` (JPEG/MP4).
    ///   - progresso: callback chamado a cada asset processado com
    ///     `(enviadosNestaExecucao, totalPendente)`. Sempre invocado fora do actor.
    /// - Returns: número de assets efetivamente copiados nesta execução.
    /// - Throws: um `SyncError` em caso de falha irrecuperável.
    @discardableResult
    func sync(
        folderName: String,
        formato: ExportFormat = SyncConfig.formatoPadrao,
        progresso: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int {
        resetarCancelamento()

        // 1. Garantias de pré-condição (permissão + pasta) antes de qualquer I/O.
        try await requestAuthorization()
        await tracker.load()
        let destino = try resolverPastaDestino(folderName: folderName)

        // 2. Levanta os assets e calcula quantos ainda estão pendentes, para que a
        //    barra de progresso reflita apenas o trabalho real desta execução.
        let assets = buscarAssets()
        var pendentes: [PHAsset] = []
        pendentes.reserveCapacity(assets.count)

        for indice in 0..<assets.count {
            let asset = assets.object(at: indice)
            let jaFeito = await tracker.isSynced(asset.localIdentifier)
            if !jaFeito {
                pendentes.append(asset)
            }
        }

        let total = pendentes.count
        var enviados = 0
        progresso(enviados, total)

        // 3. Exporta cada asset pendente.
        for asset in pendentes {
            // Cancelamento cooperativo (ex.: expiração da BG task).
            if cancelado { throw SyncError.cancelada }

            try await exportarAsset(asset, para: destino, formato: formato)

            // Só marca no livro-razão APÓS a escrita coordenada bem-sucedida.
            try await tracker.markSynced(asset.localIdentifier)

            enviados += 1
            progresso(enviados, total)
        }

        return enviados
    }

    // MARK: - Exportação de um asset (dispatcher por formato)

    /// Ponto único de exportação de um asset. Encaminha para o caminho de dados
    /// brutos (`.original`) ou para o caminho de conversão universal (`.compativel`).
    private func exportarAsset(
        _ asset: PHAsset,
        para destino: URL,
        formato: ExportFormat
    ) async throws {
        switch formato {
        case .original:
            try await exportarRecursosOriginais(asset, para: destino)
        case .compativel:
            try await exportarCompativel(asset, para: destino)
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
    private func exportarRecursosOriginais(_ asset: PHAsset, para destino: URL) async throws {
        let recursos = PHAssetResource.assetResources(for: asset)
        guard !recursos.isEmpty else {
            // Sem recursos acessíveis (asset degradado). Não é fatal para os demais,
            // mas sinalizamos para que o chamador registre o problema.
            throw SyncError.recursoIndisponivel(nomeArquivo: asset.localIdentifier)
        }

        // Prefixo curto e estável derivado do localIdentifier, para evitar colisões
        // entre arquivos de mesmo nome originados de assets diferentes.
        let prefixo = Self.prefixoEstavel(para: asset.localIdentifier)

        for recurso in recursos {
            guard Self.deveExportar(recurso.type) else { continue }

            let nomeArquivo = "\(prefixo)_\(recurso.originalFilename)"
            let destinoFinal = destino.appendingPathComponent(nomeArquivo, isDirectory: false)

            // Idempotência: se o arquivo já existe no destino, não reescreve. Isso
            // reforça o one-way (nunca sobrescrevemos/removemos cópias existentes).
            if FileManager.default.fileExists(atPath: destinoFinal.path) {
                continue
            }

            // 3a. Escreve os dados originais em um arquivo TEMPORÁRIO local.
            //     writeData(for:toFile:) faz streaming para disco — não carrega
            //     vídeos inteiros em memória.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + nomeArquivo)

            try await escreverRecursoEmArquivo(recurso, tempURL: tempURL)

            // 3b. Move o arquivo temporário para a pasta de destino (escrita coordenada).
            try coordenarMovimento(de: tempURL, para: destinoFinal)
        }
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
    private func exportarCompativel(_ asset: PHAsset, para destino: URL) async throws {
        let prefixo = Self.prefixoEstavel(para: asset.localIdentifier)
        let base = Self.nomeBase(para: asset)

        switch asset.mediaType {
        case .image:
            let destinoFinal = destino.appendingPathComponent(
                "\(prefixo)_\(base).jpg", isDirectory: false)
            // Idempotência: nunca reescreve nem toca em cópia existente (one-way).
            if FileManager.default.fileExists(atPath: destinoFinal.path) { return }

            let jpeg = try await obterJPEGCompativel(asset)
            try gravarDados(jpeg, em: destinoFinal, nomeTemp: "\(base).jpg")

        case .video:
            let destinoFinal = destino.appendingPathComponent(
                "\(prefixo)_\(base).mp4", isDirectory: false)
            if FileManager.default.fileExists(atPath: destinoFinal.path) { return }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + base + ".mp4")
            try await exportarVideoH264(asset, paraArquivo: tempURL)
            try coordenarMovimento(de: tempURL, para: destinoFinal)

        default:
            // Áudio ou tipos desconhecidos: nada a exportar no modo compatível.
            return
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
    private func gravarDados(_ dados: Data, em destinoFinal: URL, nomeTemp: String) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + nomeTemp)
        do {
            try dados.write(to: tempURL, options: [.atomic])
        } catch {
            throw Self.mapearErroDeEscrita(error, nomeArquivo: destinoFinal.lastPathComponent)
        }
        try coordenarMovimento(de: tempURL, para: destinoFinal)
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
    private func coordenarMovimento(de origem: URL, para destinoFinal: URL) throws {
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
