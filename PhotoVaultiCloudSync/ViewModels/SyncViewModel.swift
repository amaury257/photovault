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

    /// Nome da pasta de backup no app Arquivos (editável nas Configurações).
    @Published var folderName: String

    /// Formato de exportação escolhido (Original ou Compatível).
    @Published var exportFormat: ExportFormat

    // MARK: - Dependências

    private let engine: PhotoSyncEngine
    private let tracker: PhotoTracker
    private let defaults: UserDefaults

    // MARK: - Init

    /// Injeta as dependências compartilhadas. Por padrão, usa as instâncias do
    /// `BackgroundSyncManager.shared` para manter estado único no app.
    init(
        engine: PhotoSyncEngine = BackgroundSyncManager.shared.engineCompartilhado,
        tracker: PhotoTracker = BackgroundSyncManager.shared.trackerCompartilhado,
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.tracker = tracker
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
        let auth = PHPhotoLibrary.authorizationStatus(for: .readOnly)
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
            let enviados = try await engine.sync(
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

            status = .completed(agora)
            _ = enviados // (contador de novos itens desta execução, se quiser exibir)
        } catch let erro as SyncError {
            status = .failed(erro.errorDescription ?? "Erro desconhecido.")
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

    /// Caminho amigável exibido nas Configurações (apenas informativo).
    /// Corresponde ao que o usuário vê no app Arquivos: No meu iPhone ▸ PhotoVault.
    var caminhoExibicao: String {
        "No meu iPhone / PhotoVault / \(folderName)"
    }
}
