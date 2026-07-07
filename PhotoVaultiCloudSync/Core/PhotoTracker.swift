//
//  PhotoTracker.swift
//  PhotoVaultiCloudSync
//
//  Livro-razão (ledger) local dos assets já copiados para a pasta de backup.
//
//  ⚠️ GARANTIA DE BACKUP UNIDIRECIONAL (ONE-WAY):
//  Este componente é o coração do requisito crítico do app. Ele guarda o conjunto
//  de `localIdentifier` de todas as fotos/vídeos que JÁ foram copiados para o backup.
//
//  - O conjunto SÓ CRESCE. Um `localIdentifier` nunca é removido só porque o asset
//    sumiu da galeria. Se o usuário apagar a foto do iPhone, o ID permanece no
//    livro-razão, então o app NÃO tenta reprocessar e, principalmente, NUNCA toca
//    na cópia que está na pasta de backup.
//  - Também evita duplicatas: antes de enviar, o motor pergunta `isSynced(_:)`.
//
//  Persistência: arquivo JSON em Application Support (escala melhor que UserDefaults
//  para bibliotecas com dezenas de milhares de itens). Metadados escalares (data da
//  última sync, nome da pasta) ficam em UserDefaults — ver SyncViewModel.
//

import Foundation

/// Gerenciador thread-safe do livro-razão de `localIdentifier` já sincronizados.
///
/// É um `actor` para serializar automaticamente todos os acessos ao conjunto em
/// memória e às gravações em disco, evitando corridas entre a sincronização manual
/// e a tarefa em background.
actor PhotoTracker {

    /// Conjunto em memória dos identificadores já copiados.
    private var syncedIDs: Set<String> = []

    /// URL do arquivo JSON de persistência (Application Support/ledger.json).
    private let ledgerURL: URL

    /// Indica se o conjunto já foi carregado do disco ao menos uma vez.
    private var carregado = false

    // MARK: - Inicialização

    /// Cria o tracker resolvendo o caminho do arquivo de ledger.
    ///
    /// - Parameter fileManager: injetável para testes; usa `.default` por padrão.
    init(fileManager: FileManager = .default) {
        // Application Support não é criado automaticamente — garantimos abaixo.
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory

        self.ledgerURL = base.appendingPathComponent(
            SyncConfig.ledgerFileName,
            isDirectory: false
        )
    }

    // MARK: - Carregamento / persistência

    /// Carrega o livro-razão do disco (idempotente — só lê na primeira chamada).
    ///
    /// Falhas de leitura/decodificação são tratadas como "ledger vazio": é seguro,
    /// pois no pior caso o app reavalia assets já copiados e a checagem de
    /// existência de arquivo os ignora — nunca apaga nada da pasta de backup.
    func load() {
        guard !carregado else { return }
        carregado = true

        guard FileManager.default.fileExists(atPath: ledgerURL.path) else {
            syncedIDs = []
            return
        }

        do {
            let data = try Data(contentsOf: ledgerURL)
            syncedIDs = try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            // Ledger corrompido/ilegível: começa vazio em vez de travar o app.
            // (One-way continua garantido porque nada é removido da pasta de backup.)
            syncedIDs = []
        }
    }

    /// Persiste o conjunto atual em disco de forma atômica.
    ///
    /// - Throws: repassa erros de codificação/escrita para o chamador registrar.
    private func save() throws {
        let data = try JSONEncoder().encode(syncedIDs)
        // `.atomic` grava em arquivo temporário e faz rename — evita corromper o
        // ledger se o processo for morto no meio da escrita.
        try data.write(to: ledgerURL, options: [.atomic])
    }

    // MARK: - API pública

    /// Retorna `true` se o asset já foi copiado para o backup anteriormente.
    func isSynced(_ localIdentifier: String) -> Bool {
        syncedIDs.contains(localIdentifier)
    }

    /// Marca um asset como sincronizado e persiste imediatamente.
    ///
    /// Persistir a cada item torna o processo resiliente: se o app for encerrado
    /// no meio de um backup longo, o progresso já registrado não se perde e não há
    /// reenvio dos itens confirmados.
    ///
    /// - Throws: `SyncError.escritaFalhou` caso a gravação do ledger falhe.
    func markSynced(_ localIdentifier: String) throws {
        // Se já estava presente, não há necessidade de reescrever o arquivo.
        guard syncedIDs.insert(localIdentifier).inserted else { return }
        do {
            try save()
        } catch {
            // Reverte a inserção em memória para manter consistência com o disco.
            syncedIDs.remove(localIdentifier)
            throw SyncError.escritaFalhou(motivo: "livro-razão: \(error.localizedDescription)")
        }
    }

    /// Quantidade de assets já copiados (tamanho do livro-razão).
    var syncedCount: Int {
        syncedIDs.count
    }

    /// Cópia imutável de todos os IDs — útil para depuração/diagnóstico.
    var todosOsIDs: Set<String> {
        syncedIDs
    }
}
