//
//  WhatsAppSyncViewModel.swift
//  PhotoVaultiCloudSync
//
//  ViewModel do backup de mídia do WhatsApp — funcionalidade SEPARADA do
//  backup de fotos da galeria, com motor, livro-razão e pastas de
//  origem/destino próprios. Só roda manualmente (sem tarefa em background).
//
//  Marcado `@MainActor`: todas as propriedades `@Published` são atualizadas
//  na thread principal.
//

import Foundation
import SwiftUI

@MainActor
final class WhatsAppSyncViewModel: ObservableObject {

    // MARK: - Estado publicado

    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var origemNome: String?
    @Published private(set) var destinoNome: String?
    @Published private(set) var totalCopiados: Int = 0
    @Published private(set) var ultimaSync: Date?

    // MARK: - Dependências (próprias — não compartilhadas com o backup de fotos)

    private let engine: WhatsAppSyncEngine
    private let tracker: WhatsAppTracker
    private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        let tracker = WhatsAppTracker()
        self.tracker = tracker
        self.engine = WhatsAppSyncEngine(tracker: tracker)
        self.defaults = defaults

        self.ultimaSync = defaults.object(forKey: SyncConfig.DefaultsKey.whatsAppLastSyncDate) as? Date

        if let data = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppSourceBookmark) {
            self.origemNome = Self.nomeAmigavel(deBookmark: data)
        }
        if let data = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark) {
            self.destinoNome = Self.nomeAmigavel(deBookmark: data)
        }
    }

    /// `true` quando origem e destino já foram escolhidos e nenhuma sync está rolando.
    var podeSincronizar: Bool {
        origemNome != nil && destinoNome != nil && !status.estaSincronizando
    }

    // MARK: - Ações

    /// Atualiza o contador de arquivos já copiados (livro-razão).
    func atualizarContagem() async {
        totalCopiados = await tracker.syncedCount
    }

    /// Persiste a pasta de ORIGEM (ex.: WhatsApp ▸ Media) via bookmark de segurança.
    func escolherOrigem(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: SyncConfig.DefaultsKey.whatsAppSourceBookmark)
        origemNome = url.lastPathComponent
    }

    /// Persiste a pasta de DESTINO via bookmark de segurança.
    func escolherDestino(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark)
        destinoNome = url.lastPathComponent
    }

    /// Dispara a sincronização manual ("Sincronizar WhatsApp Agora").
    func syncNow() async {
        guard !status.estaSincronizando else { return }
        guard
            let origemData = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppSourceBookmark),
            let destinoData = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark)
        else {
            status = .failed(SyncError.pastasNaoConfiguradas.errorDescription ?? "")
            return
        }

        status = .syncing(enviados: 0, total: 0)

        do {
            try await engine.sync(
                origemBookmark: origemData,
                destinoBookmark: destinoData
            ) { [weak self] feitos, total in
                Task { @MainActor in
                    self?.status = .syncing(enviados: feitos, total: total)
                }
            }

            let agora = Date()
            defaults.set(agora, forKey: SyncConfig.DefaultsKey.whatsAppLastSyncDate)
            ultimaSync = agora
            totalCopiados = await tracker.syncedCount
            status = .completed(agora)
        } catch let erro as SyncError {
            status = .failed(erro.errorDescription ?? "Erro desconhecido.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Reseta o livro-razão do WhatsApp (mesmo propósito do reset do backup de fotos).
    func refazerBackupCompleto() async throws {
        try await tracker.resetar()
        defaults.removeObject(forKey: SyncConfig.DefaultsKey.whatsAppLastSyncDate)
        ultimaSync = nil
        await atualizarContagem()
    }

    // MARK: - Auxiliares

    private static func nomeAmigavel(deBookmark bookmarkData: Data) -> String? {
        var estaDesatualizado = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &estaDesatualizado
        ) else {
            return nil
        }
        return url.lastPathComponent
    }
}
