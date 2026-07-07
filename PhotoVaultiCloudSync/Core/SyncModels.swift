//
//  SyncModels.swift
//  PhotoVaultiCloudSync
//
//  Modelos de dados centrais do app: estado da sincronização, erros tipados,
//  estatísticas exibidas no dashboard e as constantes de configuração.
//
//  Todo o texto voltado ao usuário está em Português (Brasil).
//

import Foundation

// MARK: - Estado da sincronização

/// Representa o estado atual do motor de sincronização.
///
/// É `Equatable` para que a SwiftUI consiga difundir mudanças de forma eficiente
/// e para facilitar testes. O caso `.syncing` carrega o progresso (0.0 a 1.0)
/// junto com contadores absolutos para alimentar a barra de progresso da UI.
enum SyncStatus: Equatable {
    /// Nenhuma sincronização em andamento (estado inicial / repouso).
    case idle
    /// Sincronizando. `enviados`/`total` alimentam a barra; `fracao` é conveniência.
    case syncing(enviados: Int, total: Int)
    /// Concluído com sucesso na data informada.
    case completed(Date)
    /// Falhou. A `String` é uma mensagem já localizada em PT-BR para exibição.
    case failed(String)

    /// Fração de progresso (0.0 – 1.0). Retorna 0 quando não está sincronizando
    /// ou quando ainda não há total conhecido (evita divisão por zero).
    var fracao: Double {
        switch self {
        case let .syncing(enviados, total):
            guard total > 0 else { return 0 }
            return min(1.0, Double(enviados) / Double(total))
        default:
            return 0
        }
    }

    /// Indica se há uma sincronização em andamento — usado para desabilitar o botão.
    var estaSincronizando: Bool {
        if case .syncing = self { return true }
        return false
    }
}

// MARK: - Erros tipados

/// Erros previsíveis do fluxo de backup. Cada caso já expõe uma descrição em
/// PT-BR via `errorDescription`, pronta para ser mostrada ao usuário.
enum SyncError: LocalizedError, Equatable {
    /// O usuário negou (ou restringiu) o acesso à biblioteca de fotos.
    case permissaoNegada
    /// (Mantido por compatibilidade — não usado na versão de backup local.)
    case iCloudIndisponivel
    /// Não foi possível localizar/criar a pasta de backup do aplicativo.
    case containerNaoEncontrado
    /// O armazenamento do dispositivo está cheio.
    case armazenamentoCheio
    /// Um recurso (dados originais) do asset não pôde ser obtido.
    case recursoIndisponivel(nomeArquivo: String)
    /// Falha genérica de escrita coordenada no disco.
    case escritaFalhou(motivo: String)
    /// A sincronização foi cancelada (ex.: expiração da tarefa em background).
    case cancelada

    var errorDescription: String? {
        switch self {
        case .permissaoNegada:
            return "Acesso à galeria de fotos negado. Autorize nas Configurações do iOS "
                + "para que o backup funcione."
        case .iCloudIndisponivel:
            return "Serviço de armazenamento indisponível."
        case .containerNaoEncontrado:
            return "Não foi possível acessar a pasta de backup do aplicativo."
        case .armazenamentoCheio:
            return "Armazenamento cheio. Libere espaço no dispositivo e tente novamente."
        case let .recursoIndisponivel(nomeArquivo):
            return "Não foi possível obter os dados originais de \"\(nomeArquivo)\". "
                + "O arquivo pode estar apenas no iCloud (Fotos) e o download falhou."
        case let .escritaFalhou(motivo):
            return "Falha ao gravar o backup: \(motivo)"
        case .cancelada:
            return "Sincronização cancelada."
        }
    }
}

// MARK: - Estatísticas do dashboard

/// Estatísticas exibidas no painel principal.
struct SyncStats: Equatable {
    /// Total de fotos + vídeos atualmente na galeria local.
    var totalNaGaleria: Int = 0
    /// Total de assets já copiados para o backup (tamanho do livro-razão).
    var totalBackupFeito: Int = 0
    /// Data/hora da última sincronização bem-sucedida (nil se nunca sincronizou).
    var ultimaSync: Date? = nil
}

// MARK: - Formato de exportação

/// Formato em que as mídias são gravadas na pasta de backup.
///
/// - `original`: copia o arquivo exatamente como está no iPhone (HEIC/RAW para
///   fotos, HEVC/H.265 para vídeos, além do vídeo de Live Photos). Menor tamanho
///   e fidelidade máxima, porém são formatos que nem todo dispositivo/app abre.
/// - `compativel`: converte para **JPEG** (fotos) e **MP4 / H.264** (vídeos) na
///   **resolução máxima**. Abre em praticamente qualquer PC, Android ou navegador,
///   ao custo de um leve reencode.
enum ExportFormat: String, CaseIterable, Identifiable {
    case original
    case compativel

    var id: String { rawValue }

    /// Título curto exibido no seletor das Configurações.
    var titulo: String {
        switch self {
        case .original:   return "Original (máxima fidelidade)"
        case .compativel: return "Compatível (universal)"
        }
    }

    /// Descrição detalhada exibida no rodapé do seletor.
    var descricao: String {
        switch self {
        case .original:
            return "Mantém o arquivo exatamente como no iPhone (HEIC/RAW e HEVC). "
                + "Menor tamanho, mas nem todo dispositivo abre esses formatos."
        case .compativel:
            return "Converte para JPEG (fotos) e MP4/H.264 (vídeos) na resolução "
                + "máxima. Abre em qualquer PC, Android ou navegador, com um leve reencode."
        }
    }
}

// MARK: - Configuração e constantes

/// Constantes centralizadas e chaves de persistência.
///
/// Mantém "strings mágicas" em um único lugar, evitando divergência entre os
/// vários módulos (Info.plist, entitlements e código devem concordar nos IDs).
enum SyncConfig {

    /// Nome padrão da subpasta de backup criada dentro de Documents do app.
    static let nomePastaPadrao = "PhotoVault_Backup"

    /// Identificador da tarefa de processamento em background.
    ///
    /// IMPORTANTE: precisa ser idêntico ao valor declarado em
    /// `BGTaskSchedulerPermittedIdentifiers` no Info.plist.
    static let bgTaskIdentifier = "com.photovault.sync.processing"

    /// Formato de exportação padrão (usado enquanto o usuário não escolher outro).
    static let formatoPadrao: ExportFormat = .original

    /// Qualidade do JPEG no modo compatível (0.0–1.0). 0.95 preserva praticamente
    /// toda a qualidade visual com arquivos bem menores que sem compressão.
    static let jpegQualidade: Double = 0.95

    /// Chaves de `UserDefaults` para os metadados escalares.
    enum DefaultsKey {
        static let folderName = "pv.folderName"
        static let lastSyncDate = "pv.lastSyncDate"
        static let exportFormat = "pv.exportFormat"
    }

    /// Nome do arquivo do livro-razão (ledger) em Application Support.
    static let ledgerFileName = "ledger.json"
}
