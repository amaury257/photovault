//
//  MainApp.swift
//  PhotoVaultiCloudSync
//
//  Ponto de entrada do aplicativo (@main). Responsável por:
//    - Registrar a tarefa de background ANTES de o app terminar de lançar.
//    - Criar e injetar o `SyncViewModel` na hierarquia de views.
//    - Agendar o backup em background quando o app vai para segundo plano.
//

import SwiftUI

@main
struct PhotoVaultApp: App {

    /// ViewModel único da aplicação, compartilhado com todas as telas.
    @StateObject private var viewModel = SyncViewModel()

    /// Observa transições do ciclo de vida (ativo / inativo / background).
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // CRÍTICO: o registro da BG task precisa acontecer no init do App, antes
        // do fim do lançamento. Registrar depois causa exceção do sistema.
        BackgroundSyncManager.shared.registerTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .task {
                    // Solicita a permissão de fotos logo no primeiro uso e atualiza
                    // os contadores. Erros de permissão são refletidos na própria UI
                    // quando o usuário tocar em "Sincronizar Agora".
                    await viewModel.refreshCounts()
                    // Autorização de notificações locais (avisa conclusão do backup,
                    // essencial para as execuções em background). Falha silenciosa
                    // se o usuário negar — não afeta o backup em si.
                    await NotificationManager.shared.requestAuthorization()
                }
        }
        .onChange(of: scenePhase) { novaFase in
            // Ao ir para segundo plano, agenda a próxima passada de backup.
            if novaFase == .background {
                BackgroundSyncManager.shared.scheduleProcessing()
            }
        }
    }
}
