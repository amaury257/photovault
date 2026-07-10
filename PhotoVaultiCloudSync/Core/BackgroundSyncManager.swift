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

    private init() {
        let tracker = PhotoTracker()
        self.tracker = tracker
        self.engine = PhotoSyncEngine(tracker: tracker)
        // Lê a última pasta escolhida pelo usuário (ou o padrão).
        self.folderName = UserDefaults.standard
            .string(forKey: SyncConfig.DefaultsKey.folderName) ?? SyncConfig.nomePastaPadrao
        // Lê o último formato escolhido (ou o padrão).
        self.formato = UserDefaults.standard
            .string(forKey: SyncConfig.DefaultsKey.exportFormat)
            .flatMap(ExportFormat.init(rawValue:)) ?? SyncConfig.formatoPadrao
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

    // MARK: - Registro (chamado uma vez no launch)

    /// Registra o handler da tarefa em background.
    ///
    /// Precisa ser chamado ANTES de o app terminar de lançar. Registrar um
    /// identificador não declarado no Info.plist causa crash — por isso ambos
    /// usam `SyncConfig.bgTaskIdentifier`.
    func registerTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncConfig.bgTaskIdentifier,
            using: nil // usa uma fila padrão gerenciada pelo sistema
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // O launchHandler é invocado fora da main thread. Fazemos o hop
            // explícito para a MainActor, pois `handleProcessing` (e o
            // BGTaskScheduler) devem ser tocados a partir dela.
            Task { @MainActor in
                BackgroundSyncManager.shared.handleProcessing(task: processingTask)
            }
        }
        log.info("Tarefa em background registrada: \(SyncConfig.bgTaskIdentifier, privacy: .public)")
    }

    // MARK: - Agendamento

    /// Agenda a próxima execução de backup em segundo plano.
    ///
    /// - `requiresExternalPower`: só roda com o aparelho carregando (backup pesado).
    /// - `requiresNetworkConnectivity`: rede p/ baixar originais do iCloud Fotos, se preciso.
    /// - `earliestBeginDate`: pista para o sistema (~1h). O agendamento real fica
    ///   a critério do iOS, que pondera bateria, uso e histórico.
    func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: SyncConfig.bgTaskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // ~1 hora

        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Backup em background agendado.")
        } catch {
            // Erros comuns: recurso indisponível no simulador, ou muitas tarefas
            // pendentes. Não é fatal — a sync manual continua funcionando.
            log.error("Falha ao agendar backup em background: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Execução da tarefa

    /// Manipula a execução da tarefa em background.
    private func handleProcessing(task: BGProcessingTask) {
        log.info("Backup em background iniciado.")

        // Sempre reagende a PRÓXIMA execução logo no início, para manter a cadência
        // mesmo que esta passada seja interrompida.
        scheduleProcessing()

        // Dispara o trabalho assíncrono. Guardamos a referência para poder cancelar
        // caso o sistema sinalize expiração do tempo disponível.
        let trabalho = Task { [engine, folderName, formato, log] in
            do {
                let resultado = try await engine.sync(folderName: folderName, formato: formato)
                // Registra a data da última sync bem-sucedida.
                UserDefaults.standard.set(Date(), forKey: SyncConfig.DefaultsKey.lastSyncDate)
                log.info("""
                    Backup em background concluído. Enviados: \(resultado.enviados, privacy: .public), \
                    falhas: \(resultado.falhas, privacy: .public)
                    """)
                await SyncHistoryStore.shared.registrar(HistoricoEntry(
                    tipo: .fotos, data: Date(),
                    enviados: resultado.enviados, falhas: resultado.falhas
                ))
                await NotificationManager.shared.notificarConclusao(tipo: .fotos, resultado: resultado)
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                task.setTaskCompleted(success: false)
            } catch let erro as SyncError {
                log.error("Backup em background falhou: \(erro.localizedDescription, privacy: .public)")
                await SyncHistoryStore.shared.registrar(HistoricoEntry(
                    tipo: .fotos, data: Date(), enviados: 0, falhas: 0,
                    erroGeral: erro.errorDescription
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

        // O sistema chama este handler quando o tempo está acabando. Precisamos
        // encerrar rápido: pedimos cancelamento cooperativo ao engine e à Task.
        task.expirationHandler = {
            Task { await self.engine.cancelar() }
            trabalho.cancel()
        }
    }
}
