//
//  SyncViewModel.swift
//  PhotoVaultiCloudSync
//
//  Camada de apresentação (MVVM). Faz a ponte entre a UI SwiftUI e o motor de
//  sincronização (`PhotoSyncEngine`) + livro-razão (`PhotoTracker`).
//
//  Reaproveita o MESMO tracker/engine do `BackgroundSyncManager`, garantindo uma
//  fonte única de verdade entre a sincronização manual e a em background.
//
//  Marcado `@MainActor`: todas as propriedades `@Published` são atualizadas na
//  thread principal, então a UI nunca é tocada fora da main thread.
//

import Foundation
import Photos
import SwiftUI

@MainActor
final class SyncViewModel: ObservableObject {

    // MARK: - Estado publicado (dirige a UI)

    /// Estado atual da sincronização (idle / syncing / completed / failed).
    @Published private(set) var status: SyncStatus = .idle

    /// Contadores e data exibidos no dashboard.
    @Published private(set) var stats: SyncStats = SyncStats()

    /// Nome da pasta de backup local no app Arquivos (usado só quando NENHUMA
    /// pasta externa foi escolhida — ver `destinoExternoNome`).
    @Published var folderName: String

    /// Formato de exportação escolhido (Original ou Compatível).
    @Published var exportFormat: ExportFormat

    /// Nome de exibição da pasta EXTERNA escolhida pelo usuário via seletor de
    /// Arquivos (pode estar no iCloud Drive). `nil` = nenhuma escolhida ainda,
    /// e o backup usa a pasta local padrão do app.
    @Published private(set) var destinoExternoNome: String?

    /// Resultado (enviados/falhas) da última execução — usado para exibir a
    /// contagem de falhas no dashboard sem misturar isso ao `SyncStatus`.
    @Published private(set) var ultimoResultado: ResultadoSync?

    // MARK: - Dependências

    private let engine: PhotoSyncEngine
    private let tracker: PhotoTracker
    private let defaults: UserDefaults

    // MARK: - Init

    /// Injeta as dependências compartilhadas. Por padrão (parâmetros `nil`), usa as
    /// instâncias do `BackgroundSyncManager.shared` para manter estado único no app.
    ///
    /// Os padrões são resolvidos DENTRO do init (contexto `@MainActor`), pois valores
    /// padrão de parâmetro não podem referenciar estado isolado ao main actor.
    init(
        engine: PhotoSyncEngine? = nil,
        tracker: PhotoTracker? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine ?? BackgroundSyncManager.shared.engineCompartilhado
        self.tracker = tracker ?? BackgroundSyncManager.shared.trackerCompartilhado
        self.defaults = defaults
        self.folderName = defaults.string(forKey: SyncConfig.DefaultsKey.folderName)
            ?? SyncConfig.nomePastaPadrao
        // Carrega o formato de exportação persistido (ou o padrão).
        self.exportFormat = defaults.string(forKey: SyncConfig.DefaultsKey.exportFormat)
            .flatMap(ExportFormat.init(rawValue:)) ?? SyncConfig.formatoPadrao
        // Carrega a última data de sync persistida.
        self.stats.ultimaSync = defaults.object(
            forKey: SyncConfig.DefaultsKey.lastSyncDate
        ) as? Date
        // Resolve (melhor esforço, só para exibição) o nome da pasta externa
        // já escolhida em uma sessão anterior, se houver.
        if let bookmarkData = defaults.data(forKey: SyncConfig.DefaultsKey.destinationBookmark) {
            self.destinoExternoNome = SecurityScopedBookmark.nomeAmigavel(deBookmark: bookmarkData)
        } else {
            self.destinoExternoNome = nil
        }
    }

    // MARK: - Ações

    /// Atualiza os contadores do dashboard (total na galeria + total já enviado).
    ///
    /// Requer permissão de fotos para contar a galeria; se ainda não houver
    /// autorização, mantém o total anterior sem lançar erro visível.
    func refreshCounts() async {
        let jaEnviados = await tracker.syncedCount
        var novoStats = stats
        novoStats.totalBackupFeito = jaEnviados

        // Só conta a galeria se já tivermos autorização (evita prompt indesejado
        // apenas por abrir a tela).
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .authorized || auth == .limited {
            novoStats.totalNaGaleria = await engine.contarAssetsNaGaleria()
        }

        stats = novoStats
    }

    /// Dispara uma sincronização manual ("Sincronizar Agora").
    ///
    /// Atualiza `status`/`stats` ao longo do processo. Erros são convertidos em
    /// `.failed(mensagem)` com texto em PT-BR já pronto para exibição.
    func syncNow() async {
        guard !status.estaSincronizando else { return }

        status = .syncing(enviados: 0, total: 0)

        do {
            // Recarrega os contadores antes de começar.
            await tracker.load()

            // O callback de progresso vem de fora da MainActor; reencaminhamos ao
            // main para atualizar a UI com segurança.
            let resultado = try await engine.sync(
                folderName: folderName,
                formato: exportFormat
            ) { [weak self] feitos, total in
                Task { @MainActor in
                    self?.status = .syncing(enviados: feitos, total: total)
                }
            }

            let agora = Date()
            defaults.set(agora, forKey: SyncConfig.DefaultsKey.lastSyncDate)

            var novoStats = stats
            novoStats.ultimaSync = agora
            novoStats.totalBackupFeito = await tracker.syncedCount
            novoStats.totalNaGaleria = await engine.contarAssetsNaGaleria()
            stats = novoStats

            ultimoResultado = resultado
            status = .completed(agora)

            await SyncHistoryStore.shared.registrar(HistoricoEntry(
                tipo: .fotos, data: agora,
                enviados: resultado.enviados, falhas: resultado.falhas
            ))
            await NotificationManager.shared.notificarConclusao(tipo: .fotos, resultado: resultado)
        } catch let erro as SyncError {
            status = .failed(erro.errorDescription ?? "Erro desconhecido.")
            await SyncHistoryStore.shared.registrar(HistoricoEntry(
                tipo: .fotos, data: Date(), enviados: 0, falhas: 0,
                erroGeral: erro.errorDescription
            ))
            await NotificationManager.shared.notificarFalha(
                tipo: .fotos, mensagem: erro.errorDescription ?? "Erro desconhecido."
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Persiste o novo nome de pasta e propaga para o gerenciador de background.
    ///
    /// O novo nome só afeta backups FUTUROS; itens já enviados permanecem onde
    /// estão (coerente com o backup unidirecional).
    func salvarFolderName(_ novoNome: String) {
        let limpo = novoNome.trimmingCharacters(in: .whitespacesAndNewlines)
        let valor = limpo.isEmpty ? SyncConfig.nomePastaPadrao : limpo
        folderName = valor
        defaults.set(valor, forKey: SyncConfig.DefaultsKey.folderName)
        BackgroundSyncManager.shared.atualizarPasta(valor)
    }

    /// Persiste o formato de exportação e o propaga ao gerenciador de background.
    ///
    /// Afeta apenas backups FUTUROS; itens já enviados permanecem no formato em que
    /// foram gravados (coerente com o backup unidirecional).
    func salvarExportFormat(_ novoFormato: ExportFormat) {
        exportFormat = novoFormato
        defaults.set(novoFormato.rawValue, forKey: SyncConfig.DefaultsKey.exportFormat)
        BackgroundSyncManager.shared.atualizarFormato(novoFormato)
    }

    /// Cria (sem persistir) o bookmark de segurança de uma pasta escolhida no
    /// seletor de Arquivos. A View chama isto IMEDIATAMENTE ao receber a URL
    /// do `.fileImporter` — antes de qualquer alerta de confirmação
    /// assíncrono (ver aviso em `SecurityScopedBookmark`) — e só aplica com
    /// `aplicarPastaDestinoExterna` depois que o usuário confirmar a troca.
    ///
    /// - Throws: `SyncError.pastaExternaInacessivel` se o sistema negar o acesso.
    func criarBookmarkPastaDestino(_ url: URL) throws -> (bookmark: Data, nome: String) {
        try SecurityScopedBookmark.criar(para: url)
    }

    /// Aplica um bookmark de pasta de destino já criado (ver
    /// `criarBookmarkPastaDestino`). A partir de agora, esta pasta passa a
    /// ter prioridade sobre a pasta local (ver
    /// `PhotoSyncEngine.resolverPastaDestino`). Itens já enviados para a
    /// pasta anterior permanecem lá — só os próximos backups usam a nova pasta.
    func aplicarPastaDestinoExterna(bookmark: Data, nome: String) {
        defaults.set(bookmark, forKey: SyncConfig.DefaultsKey.destinationBookmark)
        destinoExternoNome = nome
    }

    /// Conveniência para quando NENHUMA pasta externa estava configurada
    /// ainda (ex.: banner inicial) — não há necessidade de aviso de troca.
    ///
    /// - Throws: `SyncError.pastaExternaInacessivel` se o sistema negar o acesso.
    func salvarPastaDestinoExterna(_ url: URL) throws {
        let (bookmark, nome) = try criarBookmarkPastaDestino(url)
        aplicarPastaDestinoExterna(bookmark: bookmark, nome: nome)
    }

    /// Remove a pasta externa escolhida, revertendo o backup para a pasta local
    /// padrão do app (`folderName`, dentro de Documents).
    func removerPastaDestinoExterna() {
        defaults.removeObject(forKey: SyncConfig.DefaultsKey.destinationBookmark)
        destinoExternoNome = nil
    }

    /// Reseta o livro-razão, fazendo a PRÓXIMA sincronização reprocessar TODOS os
    /// assets da galeria — inclusive os já enviados antes.
    ///
    /// Uso típico: você quer refazer o backup do zero (ex.: para aplicar a
    /// correções/formatos atuais a fotos já enviadas por uma versão antiga do
    /// app). Isto NÃO apaga nenhum arquivo sozinho — é responsabilidade sua já
    /// ter apagado os arquivos antigos da pasta de destino ANTES de chamar isto;
    /// caso contrário, o motor vê que o arquivo já existe e simplesmente pula,
    /// sem reexportar nem corrigir nada.
    ///
    /// - Throws: erro se não conseguir persistir o livro-razão vazio.
    func refazerBackupCompleto() async throws {
        try await tracker.resetar()
        defaults.removeObject(forKey: SyncConfig.DefaultsKey.lastSyncDate)
        var novoStats = stats
        novoStats.ultimaSync = nil
        stats = novoStats
        await refreshCounts()
    }

    // MARK: - Informações de armazenamento (sob demanda)

    /// Espaço livre (em bytes) no volume da pasta de destino atual.
    /// Chamado sob demanda pela UI (Configurações) — nunca automaticamente.
    func espacoLivreDestino() async throws -> Int64 {
        try await engine.espacoLivreDestino(folderName: folderName)
    }

    /// Tamanho total (em bytes) já ocupado pela pasta de backup. Pode ser
    /// lento em bibliotecas grandes (enumera todos os arquivos).
    func tamanhoTotalBackup() async throws -> Int64 {
        try await engine.tamanhoTotalBackup(folderName: folderName)
    }

    /// Caminho amigável exibido nas Configurações (apenas informativo).
    /// Mostra a pasta externa escolhida, se houver; senão, o caminho local
    /// visível no app Arquivos: No meu iPhone ▸ iAmaury ▸ <nome>.
    var caminhoExibicao: String {
        if let destinoExternoNome {
            return destinoExternoNome
        }
        return "No meu iPhone / iAmaury / \(folderName)"
    }
}
