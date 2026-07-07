//
//  ContentView.swift
//  PhotoVaultiCloudSync
//
//  Painel principal (dashboard). Mostra o estado da sincronização, os contadores
//  (fotos na galeria / backup concluído / última sincronização) e o botão
//  proeminente "Sincronizar Agora".
//
//  Toda a UI observa o `SyncViewModel` — não há lógica de negócio aqui.
//

import SwiftUI

struct ContentView: View {

    /// ViewModel injetado pelo `MainApp` via `@EnvironmentObject`.
    @EnvironmentObject private var vm: SyncViewModel

    /// Controla a apresentação da folha de Configurações.
    @State private var mostrandoConfiguracoes = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cartaoStatus
                    grupoContadores
                    botaoSincronizar
                    rodapeInformativo
                }
                .padding()
            }
            .navigationTitle("PhotoVault")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        mostrandoConfiguracoes = true
                    } label: {
                        Image(systemName: "gearshape")
                            .accessibilityLabel("Configurações")
                    }
                }
            }
            .sheet(isPresented: $mostrandoConfiguracoes) {
                SettingsView()
                    .environmentObject(vm)
            }
            // Atualiza os contadores ao abrir a tela.
            .task {
                await vm.refreshCounts()
            }
        }
    }

    // MARK: - Cartão de status

    private var cartaoStatus: some View {
        VStack(spacing: 12) {
            Image(systemName: iconeStatus)
                .font(.system(size: 44))
                .foregroundStyle(corStatus)

            Text(tituloStatus)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            // Barra de progresso apenas durante a sincronização.
            if case let .syncing(enviados, total) = vm.status {
                VStack(spacing: 4) {
                    ProgressView(value: vm.status.fracao)
                        .tint(corStatus)
                    Text(total > 0 ? "\(enviados) de \(total)" : "Preparando…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // Mensagem de erro, quando houver.
            if case let .failed(mensagem) = vm.status {
                Text(mensagem)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(corStatus.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Contadores

    private var grupoContadores: some View {
        VStack(spacing: 0) {
            linhaContador(
                icone: "photo.on.rectangle.angled",
                titulo: "Fotos na galeria",
                valor: "\(vm.stats.totalNaGaleria)"
            )
            Divider().padding(.leading, 52)
            linhaContador(
                icone: "checkmark.circle",
                titulo: "Backup concluído",
                valor: "\(vm.stats.totalBackupFeito)"
            )
            Divider().padding(.leading, 52)
            linhaContador(
                icone: "clock.arrow.circlepath",
                titulo: "Última sincronização",
                valor: textoUltimaSync
            )
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func linhaContador(icone: String, titulo: String, valor: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icone)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 36)
            Text(titulo)
                .font(.body)
            Spacer()
            Text(valor)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Botão principal

    private var botaoSincronizar: some View {
        Button {
            Task { await vm.syncNow() }
        } label: {
            HStack {
                if vm.status.estaSincronizando {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(vm.status.estaSincronizando ? "Sincronizando…" : "Sincronizar Agora")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(vm.status.estaSincronizando)
    }

    // MARK: - Rodapé

    private var rodapeInformativo: some View {
        Text("O backup é unidirecional: apagar uma foto da galeria não a remove da pasta de backup. Os arquivos ficam no app Arquivos, em \"No meu iPhone / PhotoVault\".")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    // MARK: - Derivações de estilo a partir do status

    private var iconeStatus: String {
        switch vm.status {
        case .idle:      return "folder.badge.plus"
        case .syncing:   return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private var corStatus: Color {
        switch vm.status {
        case .idle:      return .blue
        case .syncing:   return .orange
        case .completed: return .green
        case .failed:    return .red
        }
    }

    private var tituloStatus: String {
        switch vm.status {
        case .idle:              return "Pronto para sincronizar"
        case .syncing:           return "Sincronizando…"
        case .completed:         return "Backup concluído"
        case .failed:            return "Falha na sincronização"
        }
    }

    private var textoUltimaSync: String {
        guard let data = vm.stats.ultimaSync else { return "Nunca" }
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.dateStyle = .short
        formatador.timeStyle = .short
        return formatador.string(from: data)
    }
}

#Preview {
    ContentView()
        .environmentObject(SyncViewModel())
}
