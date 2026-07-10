//
//  WhatsAppSyncViewModel.swift
//  PhotoVaultiCloudSync
//
//  ViewModel do backup de mídia do WhatsApp — funcionalidade SEPARADA do
//  backup de fotos da galeria, com motor, livro-razão e pastas de
//  origem/destino próprios. Só roda manualmente (sem tarefa em background,
//  por escolha explícita do usuário).
//
//  Suporta MÚLTIPLAS pastas de origem (ex.: "WhatsApp Images" e "WhatsApp
//  Video" separadamente) — o WhatsApp não permite filtrar por conversa, então
//  isto é o mais próximo de um "filtro" que o app pode oferecer.
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
    @Published private(set) var origens: [WhatsAppOrigemConfig] = []
    @Published private(set) var destinoNome: String?
    @Published private(set) var totalCopiados: Int = 0
    @Published private(set) var ultimaSync: Date?

    /// Resultado (enviados/falhas) da última execução — para exibir a
    /// contagem de falhas sem misturar isso ao `SyncStatus`.
    @Published private(set) var ultimoResultado: ResultadoSync?

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

        self.origens = Self.carregarOrigens(defaults: defaults)

        if let data = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark) {
            self.destinoNome = SecurityScopedBookmark.nomeAmigavel(deBookmark: data)
        }
    }

    /// `true` quando ao menos uma origem e o destino já foram escolhidos e
    /// nenhuma sync está rolando.
    var podeSincronizar: Bool {
        !origens.isEmpty && destinoNome != nil && !status.estaSincronizando
    }

    // MARK: - Carregamento / migração das origens

    /// Carrega a lista de origens persistida. Se não houver nenhuma lista
    /// salva mas existir o bookmark ÚNICO de versões anteriores ao suporte a
    /// múltiplas pastas, migra automaticamente — preservando `semNamespace`
    /// para não duplicar arquivos já copiados por essa origem.
    private static func carregarOrigens(defaults: UserDefaults) -> [WhatsAppOrigemConfig] {
        if let dados = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppOrigens),
           let lista = try? JSONDecoder().decode([WhatsAppOrigemConfig].self, from: dados) {
            return lista
        }

        guard let bookmarkAntigo = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppSourceBookmark) else {
            return []
        }

        let nome = SecurityScopedBookmark.nomeAmigavel(deBookmark: bookmarkAntigo) ?? "Pasta de origem"
        let origemMigrada = WhatsAppOrigemConfig(bookmark: bookmarkAntigo, nome: nome, semNamespace: true)
        persistirOrigens([origemMigrada], defaults: defaults)
        return [origemMigrada]
    }

    private static func persistirOrigens(_ lista: [WhatsAppOrigemConfig], defaults: UserDefaults) {
        guard let dados = try? JSONEncoder().encode(lista) else { return }
        defaults.set(dados, forKey: SyncConfig.DefaultsKey.whatsAppOrigens)
    }

    // MARK: - Ações

    /// Atualiza o contador de arquivos já copiados (livro-razão).
    func atualizarContagem() async {
        totalCopiados = await tracker.syncedCount
    }

    /// Adiciona uma nova pasta de origem (ex.: WhatsApp ▸ Media) a partir de
    /// um bookmark JÁ CRIADO pela View (ver aviso em `SecurityScopedBookmark`
    /// sobre criar o bookmark imediatamente ao receber a URL do
    /// `.fileImporter`). Origens novas sempre usam namespace — não há risco
    /// de duplicar backup já existente, pois nunca foram sincronizadas antes.
    func adicionarOrigem(bookmark: Data, nome: String) {
        // Evita adicionar a mesma pasta duas vezes.
        guard !origens.contains(where: { $0.bookmark == bookmark }) else { return }
        let nova = WhatsAppOrigemConfig(bookmark: bookmark, nome: nome, semNamespace: false)
        origens.append(nova)
        Self.persistirOrigens(origens, defaults: defaults)
    }

    /// Remove uma pasta de origem da lista (não apaga nenhum arquivo já
    /// copiado — só faz o app parar de ler dessa pasta nas próximas sincronizações).
    func removerOrigem(_ origem: WhatsAppOrigemConfig) {
        origens.removeAll { $0.id == origem.id }
        Self.persistirOrigens(origens, defaults: defaults)
    }

    /// Aplica a pasta de DESTINO a partir de um bookmark já criado pela View.
    func aplicarNovoDestino(bookmark: Data, nome: String) {
        defaults.set(bookmark, forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark)
        destinoNome = nome
    }

    /// Dispara a sincronização manual ("Sincronizar WhatsApp Agora").
    func syncNow() async {
        guard !status.estaSincronizando else { return }
        guard
            !origens.isEmpty,
            let destinoData = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark)
        else {
            status = .failed(SyncError.pastasNaoConfiguradas.errorDescription ?? "")
            return
        }

        status = .syncing(enviados: 0, total: 0)

        let origensBookmarks = origens.map {
            WhatsAppOrigemBookmark(bookmark: $0.bookmark, semNamespace: $0.semNamespace)
        }

        do {
            let resultado = try await engine.sync(
                origens: origensBookmarks,
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
            ultimoResultado = resultado
            status = .completed(agora)

            await SyncHistoryStore.shared.registrar(HistoricoEntry(
                tipo: .whatsApp, data: agora,
                enviados: resultado.enviados, falhas: resultado.falhas
            ))
            await NotificationManager.shared.notificarConclusao(tipo: .whatsApp, resultado: resultado)
        } catch let erro as SyncError {
            status = .failed(erro.errorDescription ?? "Erro desconhecido.")
            await SyncHistoryStore.shared.registrar(HistoricoEntry(
                tipo: .whatsApp, data: Date(), enviados: 0, falhas: 0,
                erroGeral: erro.errorDescription
            ))
            await NotificationManager.shared.notificarFalha(
                tipo: .whatsApp, mensagem: erro.errorDescription ?? "Erro desconhecido."
            )
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

    // MARK: - Informações de armazenamento (sob demanda)

    /// Espaço livre (em bytes) no volume da pasta de destino atual.
    func espacoLivreDestino() async throws -> Int64 {
        guard let destinoData = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark) else {
            throw SyncError.pastasNaoConfiguradas
        }
        return try await engine.espacoLivreDestino(destinoBookmark: destinoData)
    }

    /// Tamanho total (em bytes) já ocupado pela pasta de backup do WhatsApp.
    func tamanhoTotalBackup() async throws -> Int64 {
        guard let destinoData = defaults.data(forKey: SyncConfig.DefaultsKey.whatsAppDestinationBookmark) else {
            throw SyncError.pastasNaoConfiguradas
        }
        return try await engine.tamanhoTotalBackup(destinoBookmark: destinoData)
    }
}
