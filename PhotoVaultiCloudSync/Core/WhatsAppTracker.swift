//
//  WhatsAppTracker.swift
//  PhotoVaultiCloudSync
//
//  Livro-razão SEPARADO do backup de mídia do WhatsApp — mesma garantia
//  one-way do PhotoTracker (o conjunto só cresce; nada é removido do destino
//  mesmo que o arquivo de origem desapareça depois).
//
//  Diferença chave: arquivos do WhatsApp não têm um `PHAsset.localIdentifier`
//  (não vêm do PhotoKit). A identidade usada aqui é o CAMINHO RELATIVO do
//  arquivo dentro da pasta de origem + o TAMANHO em bytes — estável entre
//  execuções e barato de calcular (sem precisar ler/hashear o conteúdo todo).
//

import Foundation

actor WhatsAppTracker {

    private var syncedKeys: Set<String> = []
    private let ledgerURL: URL
    private var carregado = false

    init(fileManager: FileManager = .default) {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        self.ledgerURL = base.appendingPathComponent(
            SyncConfig.whatsAppLedgerFileName,
            isDirectory: false
        )
    }

    /// Constrói a chave de identidade estável para um arquivo de origem.
    static func chave(caminhoRelativo: String, tamanho: Int) -> String {
        "\(caminhoRelativo)|\(tamanho)"
    }

    // MARK: - Carregamento / persistência (mesmo padrão do PhotoTracker)

    func load() {
        guard !carregado else { return }
        carregado = true

        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            syncedKeys = []
            return
        }
        do {
            let data = try Data(contentsOf: ledgerURL)
            syncedKeys = try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            // Ledger corrompido/ilegível: começa vazio (seguro — one-way garantido
            // porque nada é removido do destino).
            syncedKeys = []
        }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(syncedKeys)
        try data.write(to: ledgerURL, options: [.atomic])
    }

    // MARK: - API pública

    func isSynced(_ chave: String) -> Bool {
        syncedKeys.contains(chave)
    }

    func markSynced(_ chave: String) throws {
        guard syncedKeys.insert(chave).inserted else { return }
        do {
            try save()
        } catch {
            syncedKeys.remove(chave)
            throw SyncError.escritaFalhou(motivo: "livro-razão do WhatsApp: \(error.localizedDescription)")
        }
    }

    var syncedCount: Int {
        syncedKeys.count
    }

    /// Esvazia o livro-razão (mesmo propósito do `PhotoTracker.resetar()`).
    func resetar() throws {
        let anterior = syncedKeys
        syncedKeys = []
        do {
            try save()
        } catch {
            syncedKeys = anterior
            throw SyncError.escritaFalhou(motivo: "reset do livro-razão do WhatsApp: \(error.localizedDescription)")
        }
    }
}
