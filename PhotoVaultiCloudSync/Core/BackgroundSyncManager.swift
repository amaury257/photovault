//
//  BackgroundSyncManager.swift
//  PhotoVaultiCloudSync
//
//  Agenda e executa a sincronização em segundo plano usando o framework
//  BackgroundTasks. Configuramos um `BGProcessingTaskRequest`, que o sistema
//  costuma disparar quando o aparelho está ocioso e carregando — ideal para um
//  backup pesado de fotos/vídeos sem atrapalhar o uso do usuário.
//
//  Fluxo:
//    1. `registerTasks()` — chamado UMA vez no lançamento do app (antes do fim
//       do `didFinishLaunching` / init do App). Registra o handler da tarefa.
//    2. `scheduleProcessing()` — agenda a próxima execução (ex.: quando o app vai
//       para segundo plano).
//    3. Handler — roda o motor, trata a expiração e reagenda a próxima passada.
//
//  IMPORTANTE: o identificador usado aqui precisa estar declarado no Info.plist
//  em `BGTaskSchedulerPermittedIdentifiers` (ver SyncConfig.bgTaskIdentifier).
//

import Foundation
import BackgroundTasks
import Network
import UIKit
import os

/// Coordena o registro e o agendamento da tarefa de backup em background.
///
/// Marcado como `@MainActor` porque o `BGTaskScheduler` deve ser configurado a
/// partir da thread principal durante o ciclo de vida do app.
@MainActor
final class BackgroundSyncManager {

    /// Instância única para simplificar o acesso a partir do App e do ViewModel.
    static let shared = BackgroundSyncManager()

    /// Logger unificado (aparece no Console.app com subsystem/category próprios).
    private let log = Logger(subsystem: "com.photovault.sync", category: "background")

    /// Livro-razão e motor compartilhados. Reaproveitamos o mesmo tracker do app
    /// para não haver divergência de estado entre sync manual e em background.
    private let tracker: PhotoTracker
    private let engine: PhotoSyncEngine

    /// Nome da pasta de destino usado nas execuções em background. Mantido em
    /// sincronia com as Configurações via `atualizarPasta(_:)`.
    private var folderName: String

    /// Formato de exportação usado nas execuções em background. Mantido em
    /// sincronia com as Configurações via `atualizarFormato(_:)`.
    private var formato: ExportFormat

    /// `true` = agendamento automático ligado. Mantido em sincronia com as
    /// Configurações via `atualizarAgendamento(...)`. Padrão desligado
    /// (opt-in) — sem isso ligado, nenhuma tarefa é submetida ao sistema.
    private var scheduleEnabled: Bool

    /// Horário preferido (hora/minuto) para a próxima execução automática.
    private var horaPreferida: Int
    private var minutoPreferido: Int

    /// `true` = só executa se a rede atual for Wi-Fi (checado dentro da
    /// própria tarefa, já que o `BGTaskScheduler` não distingue tipo de rede).
    private var somenteWifi: Bool

    /// Filtro de conteúdo (álbuns/data mínima). Mantido em sincronia com as
    /// Configurações via `atualizarFiltro(_:)`.
    private var filtro: SyncFiltro

    /// Limite de tamanho por item fora do Wi-Fi. Mantido em sincronia via
    /// `atualizarLimiteItemForaDoWifi(_:)`. `nil` = sem limite.
    private var limiteItemBytesForaDoWifi: Int64?

    /// `true` = também faz backup de mídias de álbuns compartilhados do iCloud
    /// (subpasta "Compartilhados"). Padrão `false`. Mantido em sincronia com as
    /// Configurações via `atualizarIncluirCompartilhados(_:)`.
    private var incluirCompartilhados: Bool

    /// Identificador do "tempo extra" concedido pelo sistema (via
    /// `beginBackgroundTask`) enquanto uma sincronização MANUAL está em
    /// andamento no momento em que o app vai para segundo plano — dá alguns
    /// segundos adicionais de execução real para ela avançar antes do
    /// processo ser suspenso. Diferente do `BGProcessingTask`, que só roda
    /// numa passada FUTURA agendada pelo sistema (pode demorar).
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {
        let tracker = PhotoTracker()
        self.tracker = tracker
        self.engine = PhotoSyncEngine(tracker: tracker)
        let defaults = UserDefaults.standard
        // Lê a última pasta escolhida pelo usuário (ou o padrão).
        self.folderName = defaults
            .string(forKey: SyncConfig.DefaultsKey.folderName) ?? SyncConfig.nomePastaPadrao
        // Lê o último formato escolhido (ou o padrão).
        self.formato = defaults
            .string(forKey: SyncConfig.DefaultsKey.exportFormat)
            .flatMap(ExportFormat.init(rawValue:)) ?? SyncConfig.formatoPadrao
        // Lê as preferências de agendamento (mesmos padrões do SyncViewModel).
        self.scheduleEnabled = defaults.bool(forKey: SyncConfig.DefaultsKey.scheduleEnabled)
        self.horaPreferida = defaults.object(forKey: SyncConfig.DefaultsKey.scheduleHour) as? Int ?? 3
        self.minutoPreferido = defaults.object(forKey: SyncConfig.DefaultsKey.scheduleMinute) as? Int ?? 0
        self.somenteWifi = defaults.object(forKey: SyncConfig.DefaultsKey.scheduleWifiOnly) as? Bool ?? true

        if let dadosFiltro = defaults.data(forKey: SyncConfig.DefaultsKey.filtro),
           let filtroSalvo = try? JSONDecoder().decode(SyncFiltro.self, from: dadosFiltro) {
            self.filtro = filtroSalvo
        } else {
            self.filtro = .semFiltro
        }
        self.limiteItemBytesForaDoWifi = defaults.object(
            forKey: SyncConfig.DefaultsKey.limiteItemBytesForaDoWifi
        ) as? Int64
        self.incluirCompartilhados = defaults.bool(forKey: SyncConfig.DefaultsKey.includeShared)
    }

    /// Expõe o tracker/engine para reuso pelo ViewModel (fonte única de verdade).
    var trackerCompartilhado: PhotoTracker { tracker }
    var engineCompartilhado: PhotoSyncEngine { engine }

    /// Mantém o nome da pasta atualizado quando o usuário altera nas Configurações.
    func atualizarPasta(_ nome: String) {
        folderName = nome
    }

    /// Mantém o formato de exportação atualizado quando o usuário altera nas
    /// Configurações.
    func atualizarFormato(_ novoFormato: ExportFormat) {
        formato = novoFormato
    }

    /// Mantém o filtro de conteúdo (álbuns/data mínima) atualizado.
    func atualizarFiltro(_ novoFiltro: SyncFiltro) {
        filtro = novoFiltro
    }

    /// Mantém o limite de tamanho por item fora do Wi-Fi atualizado.
    func atualizarLimiteItemForaDoWifi(_ novoLimite: Int64?) {
        limiteItemBytesForaDoWifi = novoLimite
    }

    /// Mantém a preferência de incluir compartilhados atualizada.
    func atualizarIncluirCompartilhados(_ novoValor: Bool) {
        incluirCompartilhados = novoValor
    }

    /// Atualiza as preferências de agendamento e reagenda (ou cancela) a
    /// tarefa em background IMEDIATAMENTE — não espera o app ir para segundo
    /// plano para a mudança valer, já que o usuário acabou de mexer nisso nas
    /// Configurações.
    func atualizarAgendamento(habilitado: Bool, hora: Int, minuto: Int, somenteWifi: Bool) {
        self.scheduleEnabled = habilitado
        self.horaPreferida = hora
        self.minutoPreferido = minuto
        self.somenteWifi = somenteWifi
        scheduleProcessing()
    }

    // MARK: - Registro (chamado uma vez no launch)

    /// Registra AMBOS os handlers de tarefas em background.
    ///
    /// Precisa ser chamado ANTES de o app terminar de lançar. Registrar um
    /// identificador não declarado no Info.plist causa crash.
    /// Usa duas estratégias:
    ///   - `BGProcessingTask` (pesada, só quando device ocioso + carregando + Wi-Fi)
    ///   - `BGAppRefreshTask` (leve, rápida, em qualquer condição) — detecta que há
    ///     pendências e agenda a BGProcessingTask ou faz mini-sync
    func registerTasks() {
        // Tarefa pesada: sincronização completa
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncConfig.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundSyncManager.shared.handleProcessing(task: processingTask)
            }
        }

        // Tarefa leve: detecção + agenda pesada
        // Identificador: mesmo, mas com sufixo "refresh"
        let refreshId = SyncConfig.bgTaskIdentifier + ".refresh"
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: refreshId,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                BackgroundSyncManager.shared.handleRefresh(task: refreshTask)
            }
        }

        log.info("Tarefas em background registradas: sync + refresh")

        // Agenda a primeira execução da tarefa de refresh — ela roda em ~15 min
        // e detecta pendências periodicamente.
        scheduleRefresh()
    }

    // MARK: - Handlers das tarefas

    /// Handler da tarefa de REFRESH (leve): detecta se há pendências e
    /// agenda a tarefa pesada. Esta tarefa roda frequentemente, mesmo quando
    /// o device não está ocioso — garante que a sincronização pesada seja
    /// agendada regularmente.
    private func handleRefresh(task: BGAppRefreshTask) {
        log.info("Refresh leve iniciado — detectando se há pendências.")

        // Agenda imediatamente a próxima execução leve (em ~15 min).
        scheduleRefresh()

        // Detecta se há pendências em background.
        Task {
            await tracker.load()
            let hasPendencies = (UserDefaults.standard.stringArray(
                forKey: SyncConfig.DefaultsKey.pendingUploadRelativePaths
            ) ?? []).count > 0
            let syncedCount = await tracker.syncedCount

            if hasPendencies || syncedCount == 0 {
                self.log.debug("Pendências detectadas — agendando tarefa pesada.")
                self.scheduleProcessing()
            }

            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Continuação imediata (sync manual interrompida ao minimizar)

    /// Solicita tempo extra de execução ao sistema para uma sincronização
    /// MANUAL em andamento continuar avançando por mais alguns segundos após
    /// o app ser minimizado, em vez de congelar imediatamente. Chamado pelo
    /// `MainApp` ao detectar a transição para `.background` enquanto
    /// `status.estaSincronizando` é `true`.
    func solicitarTempoExtra() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "com.photovault.sync.continuacao"
        ) { [weak self] in
            guard let self else { return }
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    /// Libera o tempo extra solicitado — chamado ao voltar para o primeiro
    /// plano. Sem isso, o app fica marcado como "em background task" até o
    /// sistema encerrar à força, o que pode penalizar futuras concessões.
    func liberarTempoExtra() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// Agenda uma continuação da sincronização O MAIS CEDO POSSÍVEL
    /// (`earliestBeginDate = nil`), **independente** do toggle "Agendamento
    /// automático". Diferente de `scheduleProcessing()` — que só agenda a
    /// passada NOTURNA opcional, e só quando o usuário ligou esse recurso —
    /// esta função cobre um caso mais básico: "termine o backup que já
    /// começou", que deve funcionar sempre, mesmo com o agendamento
    /// desligado. Chamada quando o app minimiza com uma sync em andamento
    /// ou com pendências detectadas (`SyncViewModel.temPendenciasDeSync`).
    func agendarContinuacaoUrgente() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SyncConfig.bgTaskIdentifier)

        let request = BGProcessingTaskRequest(identifier: SyncConfig.bgTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        // earliestBeginDate = nil → "assim que possível", à discrição do iOS
        // (ainda pondera bateria/uso recente, mas sem esperar um horário fixo).

        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Continuação urgente da sincronização agendada (assim que possível).")
        } catch {
            log.error("Falha ao agendar continuação urgente: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Agendamento

    /// Agenda a próxima execução de REFRESH (tarefa leve).
    /// Roda a cada ~15 minutos, mesmo que device não esteja ocioso.
    private func scheduleRefresh() {
        let refreshId = SyncConfig.bgTaskIdentifier + ".refresh"
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshId)

        let request = BGAppRefreshTaskRequest(identifier: refreshId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // ~15 min
        do {
            try BGTaskScheduler.shared.submit(request)
            log.debug("Refresh agendado para ~15 minutos.")
        } catch {
            log.error("Falha ao agendar refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Agenda a próxima execução de backup em segundo plano, respeitando o
    /// horário preferido do usuário — ou cancela qualquer agendamento
    /// pendente se a sincronização automática estiver desligada.
    ///
    /// - `requiresExternalPower`: `false` de propósito. Exigir o aparelho
    ///   carregando junto de um HORÁRIO específico escolhido pelo usuário
    ///   tornaria o recurso quase inútil na prática (a maioria não está
    ///   carregando às 03:00 nem em qualquer hora fixa do dia).
    /// - `requiresNetworkConnectivity`: precisa de rede para eventualmente
    ///   baixar originais do iCloud Fotos que não estejam no aparelho — a
    ///   distinção Wi-Fi/dados móveis é reforçada manualmente dentro da
    ///   própria tarefa (ver `handleProcessing`), pois o `BGTaskScheduler`
    ///   não expõe esse controle.
    /// - `earliestBeginDate`: a PRÓXIMA ocorrência do horário preferido (hoje,
    ///   se ainda não passou; amanhã, caso contrário). É só uma pista para o
    ///   sistema — o momento real de execução fica a critério do iOS, que
    ///   pondera bateria, uso recente e conectividade, e pode adiar por
    ///   minutos ou horas.
    func scheduleProcessing() {
        // Sempre cancela o que houver pendente antes de decidir de novo —
        // evita acumular requests obsoletos com horários antigos.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: SyncConfig.bgTaskIdentifier)

        guard scheduleEnabled else {
            log.info("Agendamento automático desligado — nenhuma tarefa submetida.")
            return
        }

        let request = BGProcessingTaskRequest(identifier: SyncConfig.bgTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Self.proximaOcorrencia(hora: horaPreferida, minuto: minutoPreferido)

        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Backup em background agendado para ~\(self.horaPreferida, privacy: .public)h\(self.minutoPreferido, privacy: .public).")
        } catch {
            // Erros comuns: recurso indisponível no simulador, ou muitas tarefas
            // pendentes. Não é fatal — a sync manual continua funcionando.
            log.error("Falha ao agendar backup em background: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Calcula a próxima data/hora em que `hora:minuto` ocorre a partir de
    /// agora — hoje, se esse horário ainda não passou; amanhã, caso contrário.
    private static func proximaOcorrencia(hora: Int, minuto: Int) -> Date {
        let calendario = Calendar.current
        let agora = Date()
        let candidatoHoje = calendario.date(
            bySettingHour: hora, minute: minuto, second: 0, of: agora
        ) ?? agora
        if candidatoHoje > agora {
            return candidatoHoje
        }
        return calendario.date(byAdding: .day, value: 1, to: candidatoHoje) ?? candidatoHoje
    }

    /// Checagem pontual (não contínua) do tipo de rede atual, usada para
    /// respeitar a preferência "Somente Wi-Fi". Espera até 3s pela primeira
    /// atualização do `NWPathMonitor`; se não chegar a tempo, assume que NÃO
    /// está em Wi-Fi (mais seguro para não gastar dados móveis sem querer).
    private func estaEmWifi() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let fila = DispatchQueue(label: "com.photovault.sync.wifiCheck")
            let lock = NSLock()
            var jaRespondeu = false

            monitor.pathUpdateHandler = { caminho in
                lock.lock()
                defer { lock.unlock() }
                guard !jaRespondeu else { return }
                jaRespondeu = true
                monitor.cancel()
                continuation.resume(returning: caminho.usesInterfaceType(.wifi))
            }
            monitor.start(queue: fila)

            fila.asyncAfter(deadline: .now() + 3) {
                lock.lock()
                defer { lock.unlock() }
                guard !jaRespondeu else { return }
                jaRespondeu = true
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Execução da tarefa

    /// Manipula a execução da tarefa em background (pesada).
    private func handleProcessing(task: BGProcessingTask) {
        log.info("Backup em background iniciado.")

        // ANTES de iniciar a Task, registra o expirationHandler — garante que
        // será chamado se o iOS matar a tarefa inesperadamente.
        var trabalho: Task<Void, Never>?
        task.expirationHandler = {
            self.log.warning("Backup em background expirou — cancelando.")
            if let t = trabalho {
                t.cancel()
            }
            // Reagenda imediatamente para continuar depois.
            self.scheduleProcessing()
            task.setTaskCompleted(success: false)
        }

        // Dispara o trabalho assíncrono. Guardamos a referência para poder cancelar
        // caso o sistema sinalize expiração do tempo disponível.
        trabalho = Task { [engine, folderName, formato, somenteWifi, filtro, incluirCompartilhados, limiteItemBytesForaDoWifi, log] in
            // Determina o tipo de rede uma única vez — usado tanto para a
            // preferência "Somente Wi-Fi" quanto para o limite de tamanho
            // por item fora do Wi-Fi.
            let emWifi = await self.estaEmWifi()

            // Reforça "Somente Wi-Fi" manualmente — o BGTaskScheduler não tem
            // essa distinção. Se a rede atual não bater, pula esta passada sem
            // marcar como falha (a próxima, já reagendada acima, tenta de novo).
            if somenteWifi, !emWifi {
                log.info("Backup em background pulado: preferência é Somente Wi-Fi e a rede atual não é Wi-Fi.")
                task.setTaskCompleted(success: true)
                return
            }

            do {
                let resultado = try await engine.sync(
                    folderName: folderName, formato: formato, filtro: filtro,
                    incluirCompartilhados: incluirCompartilhados,
                    limiteItemBytesForaDoWifi: limiteItemBytesForaDoWifi, emWifi: emWifi
                )
                // Registra a data da última sync bem-sucedida.
                UserDefaults.standard.set(Date(), forKey: SyncConfig.DefaultsKey.lastSyncDate)
                // Best-effort: mantém a cópia do livro-razão dentro da pasta de
                // destino em dia (ver `PhotoSyncEngine.exportarLedgerParaDestino`).
                try? await engine.exportarLedgerParaDestino(folderName: folderName, tracker: self.tracker)
                // Não fica esperando o upload no iCloud aqui — o orçamento de
                // tempo de uma BGProcessingTask é curto demais para o polling.
                // Só acumula os caminhos na lista de pendentes; a checagem real
                // acontece na próxima vez que o app abrir (ver
                // `SyncViewModel.refreshCounts`) ou numa próxima sincronização.
                if !resultado.caminhosRelativosCopiados.isEmpty {
                    let defaults = UserDefaults.standard
                    let existentes = defaults.stringArray(
                        forKey: SyncConfig.DefaultsKey.pendingUploadRelativePaths
                    ) ?? []
                    let combinados = Array(Set(existentes + resultado.caminhosRelativosCopiados))
                    defaults.set(combinados, forKey: SyncConfig.DefaultsKey.pendingUploadRelativePaths)
                }
                log.info("""
                    Backup em background concluído. Enviados: \(resultado.enviados, privacy: .public), \
                    falhas: \(resultado.falhas, privacy: .public)
                    """)
                await SyncHistoryStore.shared.registrar(HistoricoEntry(
                    tipo: .fotos, data: Date(),
                    enviados: resultado.enviados, falhas: resultado.falhas,
                    origem: .automatico
                ))
                await NotificationManager.shared.notificarConclusao(tipo: .fotos, resultado: resultado)
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                task.setTaskCompleted(success: false)
            } catch let erro as SyncError {
                log.error("Backup em background falhou: \(erro.localizedDescription, privacy: .public)")
                await SyncHistoryStore.shared.registrar(HistoricoEntry(
                    tipo: .fotos, data: Date(), enviados: 0, falhas: 0,
                    erroGeral: erro.errorDescription, origem: .automatico
                ))
                await NotificationManager.shared.notificarFalha(
                    tipo: .fotos, mensagem: erro.errorDescription ?? "Erro desconhecido."
                )
                task.setTaskCompleted(success: false)
            } catch {
                log.error("Backup em background falhou: \(error.localizedDescription, privacy: .public)")
                task.setTaskCompleted(success: false)
            }
        }

        // Reagenda a próxima execução ao final desta (bem-sucedida ou não).
        // Isto garante que a cadência de sync se mantenha contínua.
        scheduleProcessing()
    }
}
