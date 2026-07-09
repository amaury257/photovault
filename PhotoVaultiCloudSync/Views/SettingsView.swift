//
//  SettingsView.swift
//  PhotoVaultiCloudSync
//
//  Tela de Configurações. Permite ao usuário:
//    - Escolher, via seletor de Arquivos do sistema, uma pasta EXTERNA de
//      destino (pode estar dentro do iCloud Drive ou qualquer outro provedor).
//      Não exige conta paga de desenvolvedor: usa o seletor do sistema, não
//      um container de iCloud próprio do app.
//    - Alternativamente, nomear a subpasta LOCAL usada quando nenhuma pasta
//      externa é escolhida.
//    - Escolher o formato de exportação (Original/Compatível).
//  Alterações valem apenas para backups futuros.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {

    @EnvironmentObject private var vm: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    /// Cópia editável do nome da pasta local (só é persistida ao tocar em "Salvar").
    @State private var nomeEditavel: String = ""

    /// Controla a apresentação do seletor de pasta do sistema.
    @State private var mostrandoPicker = false

    /// Mensagem de erro do seletor de pasta, se algo der errado.
    @State private var erroPicker: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let nome = vm.destinoExternoNome {
                        LabeledContent("Pasta escolhida", value: nome)
                        Button("Alterar pasta...") {
                            mostrandoPicker = true
                        }
                        Button("Usar pasta local do app em vez disso") {
                            vm.removerPastaDestinoExterna()
                        }
                    } else {
                        Button {
                            mostrandoPicker = true
                        } label: {
                            Label("Escolher pasta de destino...", systemImage: "folder.badge.plus")
                        }
                    }

                    if let erroPicker {
                        Text(erroPicker)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Pasta de destino")
                } footer: {
                    if vm.destinoExternoNome != nil {
                        Text("Os backups são salvos na pasta escolhida acima. Alterar ou remover "
                            + "afeta apenas os próximos backups — os arquivos já enviados "
                            + "permanecem onde estão.")
                    } else {
                        Text("Toque para escolher, no app Arquivos, uma pasta de destino — pode "
                            + "estar dentro do iCloud Drive ou em qualquer outro local. Se você "
                            + "não escolher nenhuma, o app usa uma pasta local própria (abaixo).")
                    }
                }

                // A personalização do nome local só é relevante enquanto nenhuma
                // pasta externa tiver sido escolhida.
                if vm.destinoExternoNome == nil {
                    Section {
                        TextField("Nome da pasta", text: $nomeEditavel)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                    } header: {
                        Text("Pasta local (padrão)")
                    } footer: {
                        Text("Os arquivos serão salvos em \"No meu iPhone / iAmaury / \(previewNome)\", "
                            + "acessível pelo app Arquivos.")
                    }
                }

                Section {
                    Picker("Formato", selection: $vm.exportFormat) {
                        ForEach(ExportFormat.allCases) { formato in
                            Text(formato.titulo).tag(formato)
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: vm.exportFormat) { novoFormato in
                        // Persiste imediatamente e propaga ao gerenciador de background.
                        vm.salvarExportFormat(novoFormato)
                    }
                } header: {
                    Text("Formato de exportação")
                } footer: {
                    Text(vm.exportFormat.descricao
                        + "\n\nA mudança vale apenas para os próximos backups.")
                }

                Section {
                    LabeledContent("Caminho atual", value: vm.caminhoExibicao)
                } header: {
                    Text("Informações")
                } footer: {
                    Text("O backup é estritamente unidirecional. Fotos apagadas da galeria "
                        + "continuam preservadas na pasta de backup.")
                }
            }
            .navigationTitle("Configurações")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        vm.salvarFolderName(nomeEditavel)
                        dismiss()
                    }
                    .disabled(nomeSanitizado.isEmpty)
                }
            }
            // Inicializa o campo com o valor atual ao abrir a folha.
            .onAppear {
                nomeEditavel = vm.folderName
            }
            .fileImporter(
                isPresented: $mostrandoPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { resultado in
                switch resultado {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try vm.salvarPastaDestinoExterna(url)
                        erroPicker = nil
                    } catch {
                        erroPicker = "Não foi possível usar essa pasta. Tente escolher novamente."
                    }
                case .failure(let error):
                    erroPicker = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Auxiliares

    /// Nome sem espaços nas pontas — usado para validar o botão "Salvar".
    private var nomeSanitizado: String {
        nomeEditavel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Nome mostrado no preview do rodapé (cai no padrão se estiver vazio).
    private var previewNome: String {
        nomeSanitizado.isEmpty ? SyncConfig.nomePastaPadrao : nomeSanitizado
    }
}

#Preview {
    SettingsView()
        .environmentObject(SyncViewModel())
}
