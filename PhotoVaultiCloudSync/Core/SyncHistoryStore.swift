//
//  SyncHistoryStore.swift
//  PhotoVaultiCloudSync
//
//  Persiste um histórico local (JSON em Application Support) das execuções de
//  sincronização — fotos e WhatsApp, manuais ou em background — para a tela de
//  Histórico. Independente dos livros-razão (que controlam o QUE já foi
//  copiado): isto é só um LOG do que aconteceu em cada execução, para consulta.
//
//  Compartilhado (`shared`) porque é alimentado a partir de três lugares
//  diferentes: o `SyncViewModel`, o `WhatsAppSyncViewModel` e o
//  `BackgroundSyncManager` — todos precisam ver o mesmo histórico.
//

import Foundation

actor SyncHistoryStore {

    static let shared = SyncHistoryStore()

    /// Máximo de entradas mantidas (as mais antigas são descartadas).
    private static let limiteEntradas = 200

    private var entradas: [HistoricoEntry] = []
    private var carregado = false
    private let arquivoURL: URL

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        self.arquivoURL = base.appendingPathComponent("history.json", isDirectory: false)
    }

    /// Adiciona uma entrada ao topo do histórico (mais recente primeiro) e persiste.
    func registrar(_ entrada: HistoricoEntry) {
        carregarSeNecessario()
        entradas.insert(entrada, at: 0)
        if entradas.count > Self.limiteEntradas {
            entradas.removeLast(entradas.count - Self.limiteEntradas)
        }
        salvar()
    }

    /// Retorna todas as entradas, mais recentes primeiro.
    func todas() -> [HistoricoEntry] {
        carregarSeNecessario()
        return entradas
    }

    /// Apaga todo o histórico (não afeta os livros-razão nem os arquivos copiados).
    func limpar() {
        carregarSeNecessario()
        entradas = []
        salvar()
    }

    private func carregarSeNecessario() {
        guard !carregado else { return }
        carregado = true
        guard let dados = try? Data(contentsOf: arquivoURL) else { return }
        // Histórico corrompido/ilegível: começa vazio — não é um dado crítico
        // (o livro-razão, que garante o one-way, é um arquivo separado).
        entradas = (try? JSONDecoder().decode([HistoricoEntry].self, from: dados)) ?? []
    }

    private func salvar() {
        guard let dados = try? JSONEncoder().encode(entradas) else { return }
        try? dados.write(to: arquivoURL, options: [.atomic])
    }
}
