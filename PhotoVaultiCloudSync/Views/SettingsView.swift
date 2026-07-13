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

    /// Controla o alerta de confirmação do "Refazer backup completo".
    @State private var mostrandoConfirmacaoReset = false

    /// `true` enquanto o reset do livro-razão está em andamento.
    @State private var resetando = false

    /// Erro do reset, se algo der errado.
    @State private var erroReset: String?

    /// Bookmark de uma nova pasta de destino já escolhida, aguardando
    /// confirmação do usuário (só é pedida quando JÁ havia uma pasta externa
    /// configurada — trocar de pasta local pra local não precisa de aviso).
    @State private var destinoPendente: (bookmark: Data, nome: String)?
    @State private var mostrandoConfirmacaoTrocaPasta = false

    /// Espaço em disco (consultado sob demanda — pode ser lento).
    @State private var espacoLivreTexto: String?
    @State private var tamanhoBackupTexto: String?
    @State private var carregandoEspaco = false
    @State private var erroEspaco: String?

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

                Section {
                    if let espacoLivreTexto {
                        LabeledContent("Espaço livre no iPhone", value: espacoLivreTexto)
                    }
                    if let tamanhoBackupTexto {
                        LabeledContent("Tamanho do backup", value: tamanhoBackupTexto)
                    }
                    Button {
                        Task { await verificarEspaco() }
                    } label: {
                        if carregandoEspaco {
                            HStack {
                                ProgressView()
                                Text("Calculando…")
                            }
                        } else {
                            Text("Verificar espaço em disco")
                        }
                    }
                    .disabled(carregandoEspaco)
                    if let erroEspaco {
                        Text(erroEspaco)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Armazenamento")
                } footer: {
                    Text("Calcular o tamanho do backup pode demorar em bibliotecas grandes. Não "
                        + "existe uma API pública para consultar o espaço TOTAL da sua conta "
                        + "iCloud (Fotos + Backup + Drive) — essa informação só fica disponível em "
                        + "Ajustes ▸ [seu nome] ▸ iCloud, no próprio iOS.")
                }

                Section {
                    LabeledContent("Status") {
                        Text(vm.statusUploadICloud.resumoTexto)
                            .multilineTextAlignment(.trailing)
                    }
                    Button {
                        Task { await vm.verificarUploadICloud() }
                    } label: {
                        if vm.verificandoUpload {
                            HStack {
                                ProgressView()
                                Text("Verificando…")
                            }
                        } else {
                            Text("Verificar uploads pendentes agora")
                        }
                    }
                    .disabled(vm.verificandoUpload)
                } header: {
                    Text("Upload no iCloud")
                } footer: {
                    Text("Só se aplica quando a pasta de destino escolhida acima está dentro do "
                        + "iCloud Drive. Confirma, arquivo por arquivo, se o envio para os "
                        + "servidores da Apple já terminou (não só a cópia local) — útil antes de "
                        + "apagar as fotos originais do iPhone, por exemplo.")
                }

                Section {
                    Toggle("Sincronização automática", isOn: $vm.agendamentoHabilitado)

                    if vm.agendamentoHabilitado {
                        DatePicker(
                            "Horário preferido",
                            selection: $vm.agendamentoHorario,
                            displayedComponents: .hourAndMinute
                        )
                        Picker("Rede permitida", selection: $vm.agendamentoSomenteWifi) {
                            Text("Somente Wi-Fi").tag(true)
                            Text("Wi-Fi e dados móveis").tag(false)
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Agendamento automático")
                } footer: {
                    Text("O iOS decide o momento real da execução — não é um alarme exato. Ele "
                        + "considera bateria, uso recente do app e conectividade, e pode adiar a "
                        + "tarefa por minutos ou até algumas horas. \"Somente Wi-Fi\" é verificado "
                        + "no momento da execução; se a rede não bater, o app pula essa passada "
                        + "e tenta de novo mais tarde, sem gastar dados móveis.")
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

                    if let erroReset {
                        Text(erroReset)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Avançado")
                } footer: {
                    Text("Esvazia o controle interno de \"já enviados\", fazendo o próximo "
                        + "\"Sincronizar Agora\" reprocessar TODA a galeria — inclusive fotos já "
                        + "copiadas antes. Use isto DEPOIS de apagar manualmente os arquivos "
                        + "antigos da pasta de destino (pelo app Arquivos); caso contrário, os "
                        + "arquivos antigos são apenas ignorados, sem correção. Pode demorar e "
                        + "usar dados/bateria em bibliotecas grandes.")
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
                        // Bookmark criado IMEDIATAMENTE — ver aviso em SecurityScopedBookmark
                        // sobre a validade transitória da URL do .fileImporter.
                        let (bookmark, nome) = try vm.criarBookmarkPastaDestino(url)
                        if vm.destinoExternoNome != nil {
                            // Já havia uma pasta externa: pede confirmação antes de trocar.
                            destinoPendente = (bookmark, nome)
                            mostrandoConfirmacaoTrocaPasta = true
                        } else {
                            vm.aplicarPastaDestinoExterna(bookmark: bookmark, nome: nome)
                        }
                        erroPicker = nil
                    } catch {
                        erroPicker = "Não foi possível usar essa pasta. Tente escolher novamente."
                    }
                case .failure(let error):
                    erroPicker = error.localizedDescription
                }
            }
            .alert("Trocar pasta de destino?", isPresented: $mostrandoConfirmacaoTrocaPasta) {
                Button("Cancelar", role: .cancel) { destinoPendente = nil }
                Button("Trocar") {
                    if let destinoPendente {
                        vm.aplicarPastaDestinoExterna(bookmark: destinoPendente.bookmark, nome: destinoPendente.nome)
                    }
                    destinoPendente = nil
                }
            } message: {
                Text("Os arquivos já enviados para \"\(vm.destinoExternoNome ?? "")\" permanecem lá. "
                    + "A partir de agora, os novos backups vão para \"\(destinoPendente?.nome ?? "")\".")
            }
            .alert("Refazer backup completo?", isPresented: $mostrandoConfirmacaoReset) {
                Button("Cancelar", role: .cancel) {}
                Button("Refazer tudo", role: .destructive) {
                    Task {
                        resetando = true
                        erroReset = nil
                        do {
                            try await vm.refazerBackupCompleto()
                        } catch {
                            erroReset = "Não foi possível resetar o livro-razão. Tente novamente."
                        }
                        resetando = false
                    }
                }
            } message: {
                Text("Isto NÃO apaga nenhuma foto ou arquivo. Só faz o app esquecer o que já "
                    + "enviou, para reprocessar tudo na próxima sincronização. Apague antes os "
                    + "arquivos antigos da pasta de destino, senão eles apenas serão ignorados.")
            }
        }
    }

    // MARK: - Auxiliares

    private func verificarEspaco() async {
        carregandoEspaco = true
        erroEspaco = nil
        do {
            async let livre = vm.espacoLivreDestino()
            async let total = vm.tamanhoTotalBackup()
            let (livreBytes, totalBytes) = try await (livre, total)
            espacoLivreTexto = StorageInfo.formatar(livreBytes)
            tamanhoBackupTexto = StorageInfo.formatar(totalBytes)
        } catch let erroSync as SyncError {
            erroEspaco = erroSync.errorDescription
        } catch {
            erroEspaco = error.localizedDescription
        }
        carregandoEspaco = false
    }

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
