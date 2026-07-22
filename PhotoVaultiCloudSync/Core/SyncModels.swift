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
    /// A pasta externa escolhida pelo usuário (via seletor de Arquivos) não
    /// pôde ser acessada — foi movida, apagada, ou a permissão expirou.
    case pastaExternaInacessivel

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
        case .pastaExternaInacessivel:
            return "Não foi possível acessar a pasta escolhida. Escolha a pasta novamente."
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

// MARK: - Resultado de uma sincronização

/// Resultado de uma execução do motor: quantos itens foram efetivamente
/// copiados e quantos falharam. Uma falha em UM item nunca aborta os demais
/// — o motor segue tentando o resto e reporta a contagem no final.
struct ResultadoSync: Equatable {
    var enviados: Int = 0
    var falhas: Int = 0
    /// Caminhos RELATIVOS à pasta de destino de todos os arquivos escritos (ou
    /// confirmados já existentes) NESTA execução — usados para verificar o
    /// status de upload no iCloud sem precisar reenumerar a pasta inteira.
    var caminhosRelativosCopiados: [String] = []
}

// MARK: - Verificação de upload no iCloud

/// Resultado de uma checagem de status de upload no iCloud Drive para um
/// conjunto de arquivos. Só faz sentido quando a pasta de destino está DENTRO
/// do iCloud Drive — para pasta local, ver `.naoAplicavel`.
enum UploadVerificationSummary: Equatable {
    /// A pasta de destino não é uma pasta do iCloud Drive (é local ou outro
    /// provedor sem essa noção de "upload") — não há nada para verificar.
    case naoAplicavel
    /// Ainda não foi feita nenhuma verificação nesta sessão.
    case desconhecido
    /// `confirmados`: já subiram por completo. `pendentes`: ainda enviando ou
    /// aguardando a vez. `comErro`: a Apple recusou o upload (ex.: sem espaço
    /// no iCloud) — vem junto da mensagem mais recente, se houver.
    case verificado(confirmados: Int, pendentes: Int, comErro: Int, ultimoErro: String?)

    var resumoTexto: String {
        switch self {
        case .naoAplicavel:
            return "Pasta local — o iCloud não está envolvido neste backup."
        case .desconhecido:
            return "Ainda não verificado."
        case let .verificado(confirmados, pendentes, comErro, _):
            var partes = ["\(confirmados) confirmado(s) no iCloud"]
            if pendentes > 0 { partes.append("\(pendentes) ainda enviando") }
            if comErro > 0 { partes.append("\(comErro) com erro") }
            return partes.joined(separator: ", ")
        }
    }
}

// MARK: - Histórico de sincronizações

/// Um registro do histórico de sincronizações (fotos ou WhatsApp), para a
/// tela de Histórico. Guardado localmente, sem relação com o livro-razão
/// (que controla o QUE já foi copiado; isto só guarda um LOG do que aconteceu
/// em cada execução, para consulta).
struct HistoricoEntry: Identifiable, Equatable {
    enum Tipo: String, Codable {
        case fotos
        case whatsApp
    }

    /// De onde a sincronização partiu: toque manual em "Sincronizar Agora"
    /// ou a tarefa automática em segundo plano (`BGProcessingTask`). Usado
    /// para saber se o agendamento automático está de fato rodando — uma
    /// sincronização manual diária mascararia um agendamento quebrado.
    enum Origem: String, Codable {
        case manual
        case automatico
    }

    var id: UUID
    var tipo: Tipo
    var data: Date
    var enviados: Int
    var falhas: Int
    /// Preenchido apenas quando a sincronização falhou POR COMPLETO (ex.:
    /// permissão negada, pasta inacessível) — não por falha de itens
    /// individuais, que já é refletida em `falhas`.
    var erroGeral: String?
    var origem: Origem
    /// Caminhos relativos (à pasta de destino) dos arquivos efetivamente
    /// copiados NESTA execução — usado pela tela de detalhe do histórico para
    /// exibir as miniaturas das fotos/vídeos deste backup. Vazio em entradas
    /// persistidas antes desta funcionalidade existir, ou quando não houve
    /// nada para copiar (0 enviados / falha geral).
    var caminhosRelativos: [String]

    init(
        id: UUID = UUID(), tipo: Tipo, data: Date, enviados: Int, falhas: Int,
        erroGeral: String? = nil, origem: Origem = .manual, caminhosRelativos: [String] = []
    ) {
        self.id = id
        self.tipo = tipo
        self.data = data
        self.enviados = enviados
        self.falhas = falhas
        self.erroGeral = erroGeral
        self.origem = origem
        self.caminhosRelativos = caminhosRelativos
    }
}

// Codable manual (em vez de sintetizado): `origem` foi adicionado depois do
// campo já existir em histórico persistido de usuários. Com sintetização
// automática, uma entrada antiga sem essa chave faria o decode do ARRAY
// INTEIRO falhar (`SyncHistoryStore` usa `try?` na lista completa),
// apagando silenciosamente todo o histórico. `decodeIfPresent` com fallback
// para `.manual` preserva a compatibilidade. `caminhosRelativos` segue o
// mesmo cuidado.
extension HistoricoEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, tipo, data, enviados, falhas, erroGeral, origem, caminhosRelativos
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        tipo = try c.decode(Tipo.self, forKey: .tipo)
        data = try c.decode(Date.self, forKey: .data)
        enviados = try c.decode(Int.self, forKey: .enviados)
        falhas = try c.decode(Int.self, forKey: .falhas)
        erroGeral = try c.decodeIfPresent(String.self, forKey: .erroGeral)
        origem = try c.decodeIfPresent(Origem.self, forKey: .origem) ?? .manual
        caminhosRelativos = try c.decodeIfPresent([String].self, forKey: .caminhosRelativos) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(tipo, forKey: .tipo)
        try c.encode(data, forKey: .data)
        try c.encode(enviados, forKey: .enviados)
        try c.encode(falhas, forKey: .falhas)
        try c.encodeIfPresent(erroGeral, forKey: .erroGeral)
        try c.encode(origem, forKey: .origem)
        try c.encode(caminhosRelativos, forKey: .caminhosRelativos)
    }
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

// MARK: - Filtro de conteúdo (álbuns e data mínima)

/// Filtro de quais assets entram no backup. Persistido nas Configurações e
/// usado tanto para contar a galeria quanto para a sincronização de fato —
/// os dois precisam concordar, senão o contador do painel mentiria sobre o
/// que realmente será copiado.
struct SyncFiltro: Codable, Equatable {
    /// Identificadores de `PHAssetCollection` selecionados. Vazio = toda a
    /// galeria (comportamento padrão, sem filtro de álbum).
    var albunsSelecionados: [String] = []
    /// Só assets criados A PARTIR desta data (inclusive). `nil` = sem limite.
    var dataMinima: Date?

    static let semFiltro = SyncFiltro()

    var estaAtivo: Bool { !albunsSelecionados.isEmpty || dataMinima != nil }
}

/// Um álbum (ou álbum inteligente relevante) listado para o usuário escolher
/// no filtro de conteúdo.
struct AlbumInfo: Identifiable, Hashable {
    var id: String
    var titulo: String
    var quantidade: Int
}

// MARK: - Configuração e constantes

/// Constantes centralizadas e chaves de persistência.
///
/// Mantém "strings mágicas" em um único lugar, evitando divergência entre os
/// vários módulos (Info.plist, entitlements e código devem concordar nos IDs).
enum SyncConfig {

    /// Nome padrão da subpasta de backup criada dentro de Documents do app.
    static let nomePastaPadrao = "iAmaury_Backup"

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
        /// Bookmark de segurança (Data) da pasta externa escolhida pelo usuário
        /// via seletor de Arquivos (pode estar dentro do iCloud Drive ou em
        /// qualquer outro provedor). Ausente = usa a pasta local padrão do app.
        static let destinationBookmark = "pv.destinationBookmarkData"

        // ---- Verificação de upload no iCloud ----
        /// Caminhos (relativos à pasta de destino) de arquivos copiados que
        /// ainda não foram confirmados como enviados ao iCloud na última
        /// checagem — para retomar a verificação em uma sessão futura.
        static let pendingUploadRelativePaths = "pv.pendingUploadRelativePaths"

        // ---- Agendamento automático ----
        /// Liga/desliga a sincronização automática em background.
        static let scheduleEnabled = "pv.scheduleEnabled"
        /// Hora preferida (0–23) para a sincronização automática.
        static let scheduleHour = "pv.scheduleHour"
        /// Minuto preferido (0–59) para a sincronização automática.
        static let scheduleMinute = "pv.scheduleMinute"
        /// `true` = só roda em Wi-Fi; `false` = permite dados móveis também.
        static let scheduleWifiOnly = "pv.scheduleWifiOnly"

        // ---- Filtro de conteúdo (álbuns e data mínima) ----
        /// `SyncFiltro` codificado em JSON.
        static let filtro = "pv.filtro"

        // ---- Limite de tamanho por item fora do Wi-Fi ----
        /// Bytes (Int64). Ausente/nil = sem limite.
        static let limiteItemBytesForaDoWifi = "pv.limiteItemBytesForaDoWifi"

        // ---- Escopo do backup ----
        /// `true` = também faz backup de mídias de álbuns compartilhados do
        /// iCloud (em uma subpasta "Compartilhados"). Padrão `false` (só a
        /// biblioteca do próprio usuário).
        static let includeShared = "pv.includeShared"
    }

    /// Nome do arquivo do livro-razão (ledger) em Application Support.
    static let ledgerFileName = "ledger.json"
}
