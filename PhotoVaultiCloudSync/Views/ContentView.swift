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
import UniformTypeIdentifiers

struct ContentView: View {

    /// ViewModel injetado pelo `MainApp` via `@EnvironmentObject`.
    @EnvironmentObject private var vm: SyncViewModel

    /// Controla a apresentação da folha de Configurações.
    @State private var mostrandoConfiguracoes = false

    /// Controla a apresentação do seletor de pasta (banner de solicitação).
    @State private var mostrandoPickerInicial = false

    /// Erro do seletor de pasta iniciado pelo banner, se houver.
    @State private var erroPickerInicial: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cartaoStatus
                    if vm.destinoExternoNome == nil {
                        bannerEscolhaPasta
                    }
                    grupoContadores
                    botaoSincronizar
                    linkBackupWhatsApp
                    linkHistorico
                    rodapeInformativo
                    versaoLabel
                }
                .padding()
            }
            .navigationTitle("iAmaury")
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
            .fileImporter(
                isPresented: $mostrandoPickerInicial,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { resultado in
                switch resultado {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try vm.salvarPastaDestinoExterna(url)
                        erroPickerInicial = nil
                    } catch {
                        erroPickerInicial = "Não foi possível usar essa pasta. Tente novamente."
                    }
                case .failure(let error):
                    erroPickerInicial = error.localizedDescription
                }
            }
            // Atualiza os contadores ao abrir a tela.
            .task {
                await vm.refreshCounts()
            }
        }
    }

    // MARK: - Banner de solicitação da pasta de destino

    /// Convida o usuário a escolher uma pasta de destino (pode ser dentro do
    /// iCloud Drive) enquanto nenhuma tiver sido escolhida. É esse banner que
    /// efetivamente "solicita" a pasta — a opção não fica só escondida em
    /// Configurações.
    private var bannerEscolhaPasta: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Escolha a pasta de destino")
                    .font(.headline)
                Spacer()
            }
            Text("Você ainda não escolheu onde salvar o backup — pode ser uma pasta dentro "
                + "do iCloud Drive. Sem escolher, o app usa uma pasta local própria.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                mostrandoPickerInicial = true
            } label: {
                Text("Escolher pasta agora")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            if let erroPickerInicial {
                Text(erroPickerInicial)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
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

            // Contagem de falhas por item da última execução (não abortam o
            // backup — só ficam pendentes para a próxima tentativa).
            if case .completed = vm.status, let resultado = vm.ultimoResultado, resultado.falhas > 0 {
                Text("\(resultado.falhas) item(ns) falharam e serão tentados na próxima sincronização.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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

    // MARK: - Backup do WhatsApp (tela informativa)

    /// Leva à tela que explica por que não há um seletor de pasta do WhatsApp
    /// (o iOS não expõe essa pasta a apps de terceiros) e como obter o mesmo
    /// resultado via "Salvar no Álbum da Câmera" + o backup de fotos acima.
    private var linkBackupWhatsApp: some View {
        NavigationLink {
            WhatsAppBackupView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "message.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 28)
                Text("Backup do WhatsApp")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Histórico

    private var linkHistorico: some View {
        NavigationLink {
            HistoryView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.purple)
                    .frame(width: 28)
                Text("Histórico de sincronizações")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Rodapé

    private var rodapeInformativo: some View {
        Text("O backup é unidirecional: apagar uma foto da galeria não a remove da pasta de backup. Os arquivos ficam no app Arquivos, em \"No meu iPhone / iAmaury\" (ou na pasta que você escolher).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    /// Selo com a versão do app (lida do bundle). Serve para o usuário conferir
    /// qual build está instalada após uma atualização pela AltStore.
    private var versaoLabel: some View {
        Text("iAmaury \(Self.appVersion)")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
    }

    /// Versão exibida (CFBundleShortVersionString), ex.: "v1.0.6".
    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v)"
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
