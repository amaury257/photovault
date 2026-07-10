//
//  WhatsAppBackupView.swift
//  PhotoVaultiCloudSync
//
//  Tela dedicada ao backup de mídia do WhatsApp — funcionalidade SEPARADA do
//  backup de fotos da galeria, com sua própria pasta de ORIGEM (a pasta que o
//  WhatsApp expõe no app Arquivos) e pasta de DESTINO.
//
//  O WhatsApp não permite escolher por conversa/contato — essa informação
//  fica presa no banco de dados interno dele, fora do alcance de qualquer
//  app de terceiros por causa do sandbox do iOS. O "filtro" possível aqui é
//  a própria pasta de origem que o usuário escolhe (ex.: apontar só para
//  "WhatsApp Images" em vez da pasta "Media" inteira).
//

import SwiftUI
import UniformTypeIdentifiers

struct WhatsAppBackupView: View {

    @StateObject private var vm = WhatsAppSyncViewModel()

    @State private var mostrandoPickerOrigem = false
    @State private var mostrandoPickerDestino = false
    @State private var erro: String?
    @State private var mostrandoConfirmacaoReset = false
    @State private var resetando = false

    var body: some View {
        Form {
            Section {
                if let origem = vm.origemNome {
                    LabeledContent("Pasta escolhida", value: origem)
                } else {
                    Text("Nenhuma pasta escolhida ainda.")
                        .foregroundStyle(.secondary)
                }
                Button("Escolher pasta de origem...") {
                    mostrandoPickerOrigem = true
                }
            } header: {
                Text("De onde ler (WhatsApp)")
            } footer: {
                Text("Aponte para Arquivos ▸ Neste iPhone ▸ WhatsApp ▸ Media (ou uma subpasta "
                    + "específica, como \"WhatsApp Images\", para restringir o que é copiado — "
                    + "o WhatsApp não permite escolher por conversa ou contato).")
            }

            Section {
                if let destino = vm.destinoNome {
                    LabeledContent("Pasta escolhida", value: destino)
                } else {
                    Text("Nenhuma pasta escolhida ainda.")
                        .foregroundStyle(.secondary)
                }
                Button("Escolher pasta de destino...") {
                    mostrandoPickerDestino = true
                }
            } header: {
                Text("Para onde copiar")
            } footer: {
                Text("Pode ser uma pasta dentro do iCloud Drive ou qualquer outro local "
                    + "acessível pelo app Arquivos.")
            }

            if let erro {
                Section {
                    Text(erro)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await vm.syncNow() }
                } label: {
                    HStack {
                        if vm.status.estaSincronizando {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(vm.status.estaSincronizando ? "Sincronizando…" : "Sincronizar WhatsApp Agora")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.podeSincronizar)

                if case let .syncing(enviados, total) = vm.status {
                    VStack(spacing: 4) {
                        ProgressView(value: vm.status.fracao)
                        Text(total > 0 ? "\(enviados) de \(total)" : "Preparando…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if case let .failed(mensagem) = vm.status {
                    Text(mensagem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("O backup é unidirecional: apagar um arquivo do WhatsApp não o remove da "
                    + "pasta de destino.")
            }

            Section {
                LabeledContent("Arquivos copiados", value: "\(vm.totalCopiados)")
                LabeledContent("Última sincronização", value: textoUltimaSync)
            } header: {
                Text("Status")
            }

            Section {
                Button(role: .destructive) {
                    mostrandoConfirmacaoReset = true
                } label: {
                    if resetando {
                        HStack {
                            ProgressView()
                            Text("Reprocessando…")
                        }
                    } else {
                        Text("Refazer backup completo")
                    }
                }
                .disabled(resetando)
            } header: {
                Text("Avançado")
            } footer: {
                Text("Esvazia o controle interno de \"já copiados\", fazendo a próxima "
                    + "sincronização reprocessar tudo. Apague antes os arquivos antigos da pasta "
                    + "de destino (pelo app Arquivos); caso contrário, eles são apenas ignorados.")
            }
        }
        .navigationTitle("Backup do WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.atualizarContagem()
        }
        .fileImporter(
            isPresented: $mostrandoPickerOrigem,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { resultado in
            switch resultado {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try vm.escolherOrigem(url)
                    erro = nil
                } catch {
                    erro = "Não foi possível usar essa pasta como origem. Tente novamente."
                }
            case .failure(let error):
                erro = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $mostrandoPickerDestino,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { resultado in
            switch resultado {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try vm.escolherDestino(url)
                    erro = nil
                } catch {
                    erro = "Não foi possível usar essa pasta como destino. Tente novamente."
                }
            case .failure(let error):
                erro = error.localizedDescription
            }
        }
        .alert("Refazer backup completo?", isPresented: $mostrandoConfirmacaoReset) {
            Button("Cancelar", role: .cancel) {}
            Button("Refazer tudo", role: .destructive) {
                Task {
                    resetando = true
                    erro = nil
                    do {
                        try await vm.refazerBackupCompleto()
                    } catch {
                        erro = "Não foi possível resetar o livro-razão. Tente novamente."
                    }
                    resetando = false
                }
            }
        } message: {
            Text("Isto NÃO apaga nenhum arquivo. Só faz o app esquecer o que já copiou, para "
                + "reprocessar tudo na próxima sincronização.")
        }
    }

    private var textoUltimaSync: String {
        guard let data = vm.ultimaSync else { return "Nunca" }
        let formatador = DateFormatter()
        formatador.locale = Locale(identifier: "pt_BR")
        formatador.dateStyle = .short
        formatador.timeStyle = .short
        return formatador.string(from: data)
    }
}

#Preview {
    NavigationStack {
        WhatsAppBackupView()
    }
}
