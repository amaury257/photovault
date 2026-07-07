//
//  SettingsView.swift
//  PhotoVaultiCloudSync
//
//  Tela de Configurações. Permite ao usuário ver e definir o NOME da pasta de
//  destino (pasta do app no Arquivos). Alterações valem apenas para backups futuros.
//

import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var vm: SyncViewModel
    @Environment(\.dismiss) private var dismiss

    /// Cópia editável do nome da pasta (só é persistida ao tocar em "Salvar").
    @State private var nomeEditavel: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome da pasta", text: $nomeEditavel)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                } header: {
                    Text("Pasta de destino (app Arquivos)")
                } footer: {
                    Text("Os arquivos serão salvos em \"No meu iPhone / PhotoVault / \(previewNome)\", "
                        + "acessível pelo app Arquivos. Alterar o nome afeta apenas os próximos "
                        + "backups — os arquivos já enviados permanecem na pasta anterior.")
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
                        + "continuam preservadas na pasta de backup do app.")
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
