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

    /// Status mais recente da verificação de upload no iCloud (ver
    /// `verificarUploadICloud`). `.desconhecido` até a primeira checagem.
    @Published private(set) var statusUploadICloud: UploadVerificationSummary = .desconhecido

    /// `true` enquanto uma checagem de upload está em andamento (polling).
    @Published private(set) var verificandoUpload = false

    // MARK: - Agendamento automático

    /// Liga/desliga a sincronização automática em background. A View chama
    /// `persistirAgendamento()` explicitamente (via `.onChange`) quando isto
    /// muda — NÃO usar `didSet` aqui: como as três propriedades de agendamento
    /// são atribuídas em sequência dentro do `init`, um `didSet` disparado na
    /// primeira tentaria ler as outras duas antes delas serem inicializadas
    /// ("used before being initialized").
    @Published var agendamentoHabilitado: Bool

    /// Horário preferido (só as componentes de hora/minuto importam — a data
    /// do `Date` em si é irrelevante, é só o que o `DatePicker` exige).
    @Published var agendamentoHorario: Date

    /// `true` = só sincroniza automaticamente em Wi-Fi; `false` = permite
    /// dados móveis também.
    @Published var agendamentoSomenteWifi: Bool

    // MARK: - Filtro de conteúdo e limite de dados móveis

    /// Quais assets entram no backup (álbuns/data mínima). `.semFiltro` =
    /// galeria inteira, comportamento padrão.
    @Published private(set) var filtro: SyncFiltro

    /// Limite de tamanho (bytes) por item ao sincronizar automaticamente
    /// FORA do Wi-Fi. `nil` = sem limite.
    @Published private(set) var limiteItemBytesForaDoWifi: Int64?

    /// `true` = também faz backup de mídias de **álbuns compartilhados do
    /// iCloud** (numa subpasta "Compartilhados"). Padrão `false` (só a
    /// biblioteca do usuário). A View persiste via `.onChange` chamando
    /// `salvarIncluirCompartilhados()`.
    @Published var incluirCompartilhados: Bool

    /// `true` quando há mais itens na galeria do que já enviados — sinaliza
    /// trabalho pendente. Usado pelo `MainApp` ao detectar que o app foi
    /// minimizado: se houver pendência (mesmo com "Agendamento automático"
    /// desligado), agenda uma continuação urgente em background — ver
    /// `BackgroundSyncManager.agendarContinuacaoUrgente()`.
    var temPendenciasDeSync: Bool {
        stats.totalNaGaleria > stats.totalBackupFeito
    }

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
        // A partir daqui, as configurações do usuário vêm de `SettingsStore`
        // (Keychain, sobrevive a reinstalações via sideload) — não mais de
        // `UserDefaults` puro. Ver `SettingsStore` para a migração automática
        // de valores legados. `lastSyncDate` continua em `UserDefaults`: é
        // estado operacional, não preferência do usuário.
        self.folderName = SettingsStore.string(forKey: SyncConfig.DefaultsKey.folderName)
            ?? SyncConfig.nomePastaPadrao
        // Carrega o formato de exportação persistido (ou o padrão).
        self.exportFormat = SettingsStore.string(forKey: SyncConfig.DefaultsKey.exportFormat)
            .flatMap(ExportFormat.init(rawValue:)) ?? SyncConfig.formatoPadrao
        // Carrega a última data de sync persistida. Atribuição do VALOR INTEIRO
        // da struct (não `self.stats.ultimaSync = ...`): mutar só um sub-campo
        // de uma propriedade `@Published` passa pelo getter do wrapper, o que o
        // verificador de inicialização definitiva do Swift trata como "leitura
        // completa de `self`" — e nesse ponto do `init` ainda haveria stored
        // properties (as de agendamento, logo abaixo) sem valor.
        self.stats = SyncStats(
            ultimaSync: defaults.object(forKey: SyncConfig.DefaultsKey.lastSyncDate) as? Date
        )
        // Resolve (melhor esforço, só para exibição) o nome da pasta externa
        // já escolhida em uma sessão anterior, se houver.
        if let bookmarkData = SettingsStore.data(forKey: SyncConfig.DefaultsKey.destinationBookmark) {
            self.destinoExternoNome = SecurityScopedBookmark.nomeAmigavel(deBookmark: bookmarkData)
        } else {
            self.destinoExternoNome = nil
        }

        // Agendamento automático: desabilitado por padrão (opt-in), horário
        // padrão 03:00, e só Wi-Fi por padrão (evita gastar dados móveis sem
        // o usuário ter escolhido isso explicitamente).
        self.agendamentoHabilitado = SettingsStore.bool(forKey: SyncConfig.DefaultsKey.scheduleEnabled) ?? false
        let horaSalva = SettingsStore.integer(forKey: SyncConfig.DefaultsKey.scheduleHour) ?? 3
        let minutoSalvo = SettingsStore.integer(forKey: SyncConfig.DefaultsKey.scheduleMinute) ?? 0
        self.agendamentoHorario = Calendar.current.date(
            bySettingHour: horaSalva, minute: minutoSalvo, second: 0, of: Date()
        ) ?? Date()
        self.agendamentoSomenteWifi = SettingsStore.bool(forKey: SyncConfig.DefaultsKey.scheduleWifiOnly) ?? true

        // Filtro de conteúdo (álbuns/data mínima) — padrão: sem filtro.
        if let dados = SettingsStore.data(forKey: SyncConfig.DefaultsKey.filtro),
           let filtroSalvo = try? JSONDecoder().decode(SyncFiltro.self, from: dados) {
            self.filtro = filtroSalvo
        } else {
            self.filtro = .semFiltro
        }

        // Limite de tamanho por item fora do Wi-Fi — padrão: sem limite.
        self.limiteItemBytesForaDoWifi = SettingsStore.int64(forKey: SyncConfig.DefaultsKey.limiteItemBytesForaDoWifi)

        // Escopo do backup: por padrão só a biblioteca do usuário (opt-in para
        // incluir os álbuns compartilhados).
        self.incluirCompartilhados = SettingsStore.bool(forKey: SyncConfig.DefaultsKey.includeShared) ?? false
    }

    /// Persiste a preferência de incluir compartilhados e a propaga ao
    /// gerenciador de background. Chamado pela View via `.onChange`.
    func salvarIncluirCompartilhados() {
        SettingsStore.set(incluirCompartilhados, forKey: SyncConfig.DefaultsKey.includeShared)
        BackgroundSyncManager.shared.atualizarIncluirCompartilhados(incluirCompartilhados)
    }

    /// Persiste as preferências de agendamento e propaga ao gerenciador de
    /// background, que reagenda (ou cancela) a tarefa imediatamente — não
    /// espera o app ir para segundo plano para a mudança valer. Chamado pela
    /// View via `.onChange` nos três controles (Toggle/DatePicker/Picker).
    func persistirAgendamento() {
        let componentes = Calendar.current.dateComponents([.hour, .minute], from: agendamentoHorario)
        let hora = componentes.hour ?? 3
        let minuto = componentes.minute ?? 0

        SettingsStore.set(agendamentoHabilitado, forKey: SyncConfig.DefaultsKey.scheduleEnabled)
        SettingsStore.set(hora, forKey: SyncConfig.DefaultsKey.scheduleHour)
        SettingsStore.set(minuto, forKey: SyncConfig.DefaultsKey.scheduleMinute)
        SettingsStore.set(agendamentoSomenteWifi, forKey: SyncConfig.DefaultsKey.scheduleWifiOnly)

        BackgroundSyncManager.shared.atualizarAgendamento(
            habilitado: agendamentoHabilitado, hora: hora, minuto: minuto,
            somenteWifi: agendamentoSomenteWifi
        )
    }

    // MARK: - Ações

    /// Evita repetir a auto-adoção do livro-razão (ver `refreshCounts`) mais
    /// de uma vez por sessão do app — não há necessidade de checar de novo a
    /// cada chamada, e a pasta de destino já foi consultada uma vez.
    private var tentouAdotarLedgerAutomaticamente = false

    /// Atualiza os contadores do dashboard (total na galeria + total já enviado).
    ///
    /// Requer permissão de fotos para contar a galeria; se ainda não houver
    /// autorização, mantém o total anterior sem lançar erro visível.
    func refreshCounts() async {
        // Auto-recuperação (uma vez por sessão): se o livro-razão local está
        // vazio, tenta adotar automaticamente o livro-razão salvo na pasta de
        // destino atual (ver `adotarLedgerDoDestino`). Cobre o caso comum de
        // reinstalação via sideload (AltStore/SideStore/iloader) que apaga a
        // sandbox do app — a pasta de destino (ex.: iCloud Drive) e o backup
        // nela continuam intactos, mas sem isto o app "esqueceria" o que já
        // foi sincronizado e reenviaria tudo de novo. Best-effort: se não
        // houver pasta configurada ainda, ou nenhum ledger salvo nela, não
        // faz nada (`adotarLedgerDoDestino` já trata os dois casos como 0).
        if !tentouAdotarLedgerAutomaticamente {
            tentouAdotarLedgerAutomaticamente = true
            if await tracker.syncedCount == 0 {
                _ = try? await engine.adotarLedgerDoDestino(folderName: folderName, tracker: tracker)
            }
        }

        let jaEnviados = await tracker.syncedCount
        var novoStats = stats
        novoStats.totalBackupFeito = jaEnviados

        // Só conta a galeria se já tivermos autorização (evita prompt indesejado
        // apenas por abrir a tela).
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if auth == .authorized || auth == .limited {
            novoStats.totalNaGaleria = await engine.contarAssetsNaGaleria(
                filtro: filtro, incluirCompartilhados: incluirCompartilhados)
        }

        stats = novoStats

        // Checagem rápida (sem esperar) de qualquer pendência de upload de
        // sessões anteriores, para o status do iCloud não ficar desatualizado
        // só por reabrir o app.
        await verificarUploadICloud(rapida: true)
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
                formato: exportFormat,
                filtro: filtro,
                incluirCompartilhados: incluirCompartilhados
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
            novoStats.totalNaGaleria = await engine.contarAssetsNaGaleria(
                filtro: filtro, incluirCompartilhados: incluirCompartilhados)
            stats = novoStats

            ultimoResultado = resultado
            status = .completed(agora)

            // Best-effort: mantém a cópia do livro-razão dentro da própria
            // pasta de destino em dia, para permitir "adotar" o backup de
            // outra instalação depois (ver `adotarLedgerDoDestino`).
            await exportarLedgerParaDestino()

            await SyncHistoryStore.shared.registrar(HistoricoEntry(
                tipo: .fotos, data: agora,
                enviados: resultado.enviados, falhas: resultado.falhas,
                caminhosRelativos: resultado.caminhosRelativosCopiados
            ))
            await NotificationManager.shared.notificarConclusao(tipo: .fotos, resultado: resultado)

            // Só DEPOIS de marcar "concluído" é que confirmamos o upload no
            // iCloud — isso pode levar dezenas de segundos (polling), então não
            // faz sentido segurar o resultado da cópia local por causa disso.
            await verificarUploadICloud(novosCaminhos: resultado.caminhosRelativosCopiados)
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
        SettingsStore.set(valor, forKey: SyncConfig.DefaultsKey.folderName)
        BackgroundSyncManager.shared.atualizarPasta(valor)
    }

    /// Persiste o formato de exportação e o propaga ao gerenciador de background.
    ///
    /// Afeta apenas backups FUTUROS; itens já enviados permanecem no formato em que
    /// foram gravados (coerente com o backup unidirecional).
    func salvarExportFormat(_ novoFormato: ExportFormat) {
        exportFormat = novoFormato
        SettingsStore.set(novoFormato.rawValue, forKey: SyncConfig.DefaultsKey.exportFormat)
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
        SettingsStore.set(bookmark, forKey: SyncConfig.DefaultsKey.destinationBookmark)
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
        SettingsStore.removeObject(forKey: SyncConfig.DefaultsKey.destinationBookmark)
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

    /// Tamanho total ESTIMADO da galeria original (fotos + vídeos, mesmo com
    /// o backup incompleto ou em formato Compatível). Pode ser lento em
    /// bibliotecas grandes (itera todos os assets).
    func tamanhoTotalGaleria() async -> Int64 {
        await engine.tamanhoTotalGaleria(filtro: filtro, incluirCompartilhados: incluirCompartilhados)
    }

    // MARK: - Filtro de conteúdo (álbuns, data mínima, limite fora do Wi-Fi)

    /// Álbuns disponíveis para o filtro (usuário + Câmera/Screenshots).
    func listarAlbuns() async -> [AlbumInfo] {
        await engine.listarAlbuns()
    }

    /// Persiste o novo filtro e atualiza os contadores (o total na galeria
    /// muda de acordo com o filtro). Propaga ao gerenciador de background,
    /// que usa o mesmo filtro nas execuções automáticas.
    func salvarFiltro(_ novoFiltro: SyncFiltro) {
        filtro = novoFiltro
        if let dados = try? JSONEncoder().encode(novoFiltro) {
            SettingsStore.set(dados, forKey: SyncConfig.DefaultsKey.filtro)
        }
        BackgroundSyncManager.shared.atualizarFiltro(novoFiltro)
        Task { await refreshCounts() }
    }

    /// Persiste o limite de tamanho por item nas sincronizações automáticas
    /// fora do Wi-Fi. `nil` = sem limite.
    func salvarLimiteItemForaDoWifi(_ novoLimite: Int64?) {
        limiteItemBytesForaDoWifi = novoLimite
        if let novoLimite {
            SettingsStore.set(novoLimite, forKey: SyncConfig.DefaultsKey.limiteItemBytesForaDoWifi)
        } else {
            SettingsStore.removeObject(forKey: SyncConfig.DefaultsKey.limiteItemBytesForaDoWifi)
        }
        BackgroundSyncManager.shared.atualizarLimiteItemForaDoWifi(novoLimite)
    }

    // MARK: - Consistência do backup (itens apagados manualmente do destino)

    /// Identificadores do livro-razão sem arquivo correspondente na pasta de
    /// destino atual — indicando que foram apagados manualmente de lá. Não
    /// altera nada, só relata.
    func verificarConsistencia() async throws -> [String] {
        try await engine.verificarConsistencia(folderName: folderName)
    }

    /// Esquece os identificadores informados (ver `verificarConsistencia`),
    /// fazendo a PRÓXIMA sincronização recopiá-los — sem reprocessar o
    /// resto da biblioteca.
    func recopiarItensAusentes(_ ids: [String]) async throws {
        try await tracker.removerSelecionados(Set(ids))
        await refreshCounts()
    }

    // MARK: - Livro-razão dentro da pasta de destino (exportar/adotar)

    /// Grava uma cópia oculta do livro-razão atual DENTRO da pasta de
    /// destino (best-effort — falhas aqui nunca comprometem o resultado da
    /// sincronização em si). Permite "adotar" o backup a partir de outra
    /// instalação do app sem reprocessar a biblioteca inteira.
    func exportarLedgerParaDestino() async {
        try? await engine.exportarLedgerParaDestino(folderName: folderName, tracker: tracker)
    }

    /// Lê o livro-razão salvo dentro da pasta de destino atual (se houver) e
    /// funde os identificadores nele com o livro-razão local — só ACRESCENTA,
    /// nunca remove (coerente com o one-way). Útil ao reinstalar o app ou
    /// trocar de aparelho, apontando para uma pasta que já tem backup.
    ///
    /// - Returns: quantos identificadores eram novos (0 = nada para adotar,
    ///   ou nenhum ledger encontrado na pasta).
    func adotarLedgerDoDestino() async throws -> Int {
        let adotados = try await engine.adotarLedgerDoDestino(folderName: folderName, tracker: tracker)
        await refreshCounts()
        return adotados
    }

    // MARK: - Verificação de upload no iCloud

    /// Caminhos (relativos à pasta de destino) ainda não confirmados como
    /// enviados ao iCloud na última checagem — persistidos para retomar em
    /// uma sessão futura (ex.: o app foi fechado com uploads grandes em curso).
    private func caminhosPendentesPersistidos() -> [String] {
        defaults.stringArray(forKey: SyncConfig.DefaultsKey.pendingUploadRelativePaths) ?? []
    }

    private func persistirCaminhosPendentes(_ caminhos: [String]) {
        defaults.set(caminhos, forKey: SyncConfig.DefaultsKey.pendingUploadRelativePaths)
    }

    /// Verifica se os arquivos do backup já terminaram de subir para o iCloud.
    ///
    /// Combina qualquer pendência de checagens anteriores com `novosCaminhos`
    /// (normalmente os arquivos recém-copiados por um `syncNow()`). Não faz
    /// nada (além de atualizar o status para `.naoAplicavel`) se a pasta de
    /// destino atual não estiver dentro do iCloud Drive.
    ///
    /// - Parameter rapida: quando `true`, faz só UMA passada de checagem (sem
    ///   esperar uploads em andamento terminarem) — usado ao simplesmente abrir
    ///   uma tela. Quando `false` (padrão, usado logo após um backup), espera
    ///   até 45s para dar tempo de uploads recentes se completarem.
    func verificarUploadICloud(novosCaminhos: [String] = [], rapida: Bool = false) async {
        guard !verificandoUpload else { return }

        let ehICloud: Bool
        do {
            ehICloud = try await engine.destinoEhICloud(folderName: folderName)
        } catch {
            // Não conseguiu nem resolver a pasta agora — deixa o status como
            // estava e tenta de novo na próxima oportunidade.
            return
        }

        guard ehICloud else {
            statusUploadICloud = .naoAplicavel
            // Pasta local não tem upload a acompanhar — descarta pendências
            // antigas (ex.: o usuário trocou de uma pasta do iCloud pra local).
            persistirCaminhosPendentes([])
            return
        }

        let combinados = Array(Set(caminhosPendentesPersistidos() + novosCaminhos))
        guard !combinados.isEmpty else {
            statusUploadICloud = .verificado(confirmados: 0, pendentes: 0, comErro: 0, ultimoErro: nil)
            return
        }

        verificandoUpload = true
        defer { verificandoUpload = false }

        do {
            let resultado = try await engine.verificarUploads(
                folderName: folderName,
                caminhosRelativos: combinados,
                timeout: rapida ? 0 : 45
            )
            // Erros de upload voltam a ser tentados na próxima checagem (a
            // Apple pode ter resolvido sozinha, ex.: espaço liberado no iCloud).
            persistirCaminhosPendentes(resultado.pendentes + resultado.comErro.map(\.caminho))
            statusUploadICloud = .verificado(
                confirmados: resultado.confirmados.count,
                pendentes: resultado.pendentes.count,
                comErro: resultado.comErro.count,
                ultimoErro: resultado.comErro.last?.mensagem
            )
        } catch {
            // Falha ao acessar a pasta — mantém os pendentes persistidos como
            // estavam, tenta de novo na próxima chamada.
        }
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
