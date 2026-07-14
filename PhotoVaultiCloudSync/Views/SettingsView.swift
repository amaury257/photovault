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

    /// Verificação de consistência (itens sumidos da pasta de destino).
    @State private var verificandoConsistencia = false
    @State private var resultadoConsistencia: [String]?
    @State private var recopiandoAusentes = false
    @State private var erroConsistencia: String?

    /// Adoção do livro-razão salvo dentro da pasta de destino.
    @State private var adotandoLedger = false
    @State private var resultadoAdocao: String?

    /// Filtro de conteúdo — cópias editáveis, sincronizadas com `vm.filtro`
    /// ao abrir a folha (mesmo padrão de `nomeEditavel`).
    @State private var dataMinimaAtiva = false
    @State private var dataMinimaValor = Date()

    /// Limite de tamanho por item fora do Wi-Fi.
    @State private var limiteAtivo = false
    @State private var limiteMB = 200

    /// Bookmark de uma nova pasta de destino já escolhida, aguardando
    /// confirmação do usuário (só é pedida quando JÁ havia uma pasta externa
    /// configurada — trocar de pasta local pra local não precisa de aviso).
    @State private var destinoPendente: (bookmark: Data, nome: String)?
    @State private var mostrandoConfirmacaoTrocaPasta = false

    /// Saúde do agendamento automático (carregado ao abrir a tela — leitura
    /// rápida do histórico, não precisa de botão "Verificar").
    @State private var ultimaExecucaoAutomatica: Date?
    @State private var carregandoStatusAgendamento = true

    /// Espaço em disco (consultado sob demanda — pode ser lento).
    @State private var espacoLivreTexto: String?
    @State private var tamanhoGaleriaTexto: String?
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
                    NavigationLink {
                        AlbumFilterView()
                    } label: {
                        LabeledContent("Álbuns", value: resumoAlbuns)
                    }

                    Toggle("Backup a partir de uma data", isOn: $dataMinimaAtiva)
                        .onChange(of: dataMinimaAtiva) { ligado in
                            aplicarFiltro(dataMinima: ligado ? dataMinimaValor : nil)
                        }
                    if dataMinimaAtiva {
                        DatePicker("Data mínima", selection: $dataMinimaValor, displayedComponents: .date)
                            .onChange(of: dataMinimaValor) { novaData in
                                aplicarFiltro(dataMinima: novaData)
                            }
                    }
                } header: {
                    Text("Filtro de conteúdo")
                } footer: {
                    Text("Restringe quais fotos e vídeos entram no backup. Sem nada marcado, vale "
                        + "a galeria inteira — comportamento padrão. Útil para excluir Screenshots "
                        + "ou deixar de fora anos já cobertos por um backup manual anterior.")
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
                    if let tamanhoGaleriaTexto {
                        LabeledContent("Tamanho da galeria", value: tamanhoGaleriaTexto)
                    }
                    if let tamanhoBackupTexto {
                        LabeledContent("Tamanho do backup", value: tamanhoBackupTexto)
                    }
                    if let espacoLivreTexto {
                        LabeledContent("Espaço livre no iPhone", value: espacoLivreTexto)
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
                    Text("\"Tamanho da galeria\" é uma estimativa da biblioteca original (pode "
                        + "demorar em bibliotecas grandes). Ela não bate com \"Tamanho do backup\" "
                        + "se a sincronização ainda não terminou, ou se o formato \"Compatível\" "
                        + "está em uso (arquivos comprimidos ficam menores que o original). Não "
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
                        .onChange(of: vm.agendamentoHabilitado) { _ in vm.persistirAgendamento() }

                    if vm.agendamentoHabilitado {
                        DatePicker(
                            "Horário preferido",
                            selection: $vm.agendamentoHorario,
                            displayedComponents: .hourAndMinute
                        )
                        .onChange(of: vm.agendamentoHorario) { _ in vm.persistirAgendamento() }

                        Picker("Rede permitida", selection: $vm.agendamentoSomenteWifi) {
                            Text("Somente Wi-Fi").tag(true)
                            Text("Wi-Fi e dados móveis").tag(false)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: vm.agendamentoSomenteWifi) { _ in vm.persistirAgendamento() }

                        if !carregandoStatusAgendamento {
                            statusAgendamentoView
                        }
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
                    Toggle("Limitar tamanho por item fora do Wi-Fi", isOn: $limiteAtivo)
                        .onChange(of: limiteAtivo) { ligado in
                            vm.salvarLimiteItemForaDoWifi(ligado ? Int64(limiteMB) * 1_000_000 : nil)
                        }
                    if limiteAtivo {
                        Picker("Limite por item", selection: $limiteMB) {
                            Text("50 MB").tag(50)
                            Text("100 MB").tag(100)
                            Text("200 MB").tag(200)
                            Text("500 MB").tag(500)
                            Text("1 GB").tag(1000)
                        }
                        .onChange(of: limiteMB) { novoMB in
                            vm.salvarLimiteItemForaDoWifi(Int64(novoMB) * 1_000_000)
                        }
                    }
                } header: {
                    Text("Dados móveis")
                } footer: {
                    Text("Só vale para a sincronização AUTOMÁTICA em segundo plano, e só quando "
                        + "\"Rede permitida\" acima inclui dados móveis. Itens maiores que o "
                        + "limite ficam pendentes até uma passada em Wi-Fi — não gastam dados nem "
                        + "contam como falha.")
                }

                Section {
                    Button {
                        Task { await verificarConsistencia() }
                    } label: {
                        if verificandoConsistencia {
                            HStack {
                                ProgressView()
                                Text("Verificando…")
                            }
                        } else {
                            Text("Verificar consistência do backup")
                        }
                    }
                    .disabled(verificandoConsistencia || recopiandoAusentes)

                    if let resultadoConsistencia {
                        if resultadoConsistencia.isEmpty {
                            Text("Tudo certo — todos os itens do livro-razão têm arquivo na pasta de destino.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(resultadoConsistencia.count) item(ns) sumiram da pasta de destino "
                                + "(provavelmente apagados manualmente).")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button {
                                Task { await recopiarAusentes() }
                            } label: {
                                if recopiandoAusentes {
                                    HStack {
                                        ProgressView()
                                        Text("Marcando para recopiar…")
                                    }
                                } else {
                                    Text("Recopiar só esses itens")
                                }
                            }
                            .disabled(recopiandoAusentes)
                        }
                    }
                    if let erroConsistencia {
                        Text(erroConsistencia)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Consistência")
                } footer: {
                    Text("Confere se os arquivos já sincronizados ainda existem na pasta de "
                        + "destino. Se algum foi apagado manualmente de lá, o livro-razão nunca "
                        + "ficaria sabendo sozinho — ele só cresce, nunca reconfere sozinho.")
                }

                Section {
                    Button {
                        Task { await adotarLedger() }
                    } label: {
                        if adotandoLedger {
                            HStack {
                                ProgressView()
                                Text("Procurando…")
                            }
                        } else {
                            Text("Adotar livro-razão da pasta de destino")
                        }
                    }
                    .disabled(adotandoLedger)

                    if let resultadoAdocao {
                        Text(resultadoAdocao)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Restaurar após reinstalar")
                } footer: {
                    Text("A cada sincronização, o app grava uma cópia oculta do livro-razão DENTRO "
                        + "da própria pasta de destino. Se você reinstalou o app (ex.: depois da "
                        + "assinatura da AltStore expirar) ou trocou de aparelho e apontou para a "
                        + "MESMA pasta que já tem backup, use este botão para reconhecer os itens "
                        + "já copiados sem reprocessar a biblioteca inteira do zero.")
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
            // Inicializa os campos com os valores atuais ao abrir a folha.
            .onAppear {
                nomeEditavel = vm.folderName
                dataMinimaValor = vm.filtro.dataMinima ?? Date()
                dataMinimaAtiva = vm.filtro.dataMinima != nil
                limiteAtivo = vm.limiteItemBytesForaDoWifi != nil
                if let limite = vm.limiteItemBytesForaDoWifi {
                    limiteMB = Int(limite / 1_000_000)
                }
            }
            .task {
                ultimaExecucaoAutomatica = await SyncHistoryStore.shared.ultimaAutomatica()?.data
                carregandoStatusAgendamento = false
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

    // MARK: - Saúde do agendamento automático

    /// Quantos dias corridos sem nenhuma execução automática, tolerados
    /// antes de destacar um aviso — o agendamento é diário, então uma
    /// lacuna maior sugere que o `BGProcessingTask` não está sendo
    /// concedido pelo iOS (comum em apps abertos raramente).
    private static let diasTolerdosSemAutomatica = 4

    @ViewBuilder
    private var statusAgendamentoView: some View {
        if let ultimaExecucaoAutomatica {
            let dias = Calendar.current.dateComponents(
                [.day], from: ultimaExecucaoAutomatica, to: Date()
            ).day ?? 0
            let atrasado = dias > Self.diasTolerdosSemAutomatica

            LabeledContent("Última execução automática") {
                Text(Self.formatadorData.string(from: ultimaExecucaoAutomatica))
                    .foregroundStyle(atrasado ? .orange : .secondary)
            }
            if atrasado {
                Text("Nenhuma sincronização automática nos últimos \(dias) dias, mesmo com o "
                    + "agendamento ligado. O iOS decide quando conceder tempo de execução em "
                    + "segundo plano — abrir o app de vez em quando ajuda o sistema a priorizar "
                    + "essa tarefa.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Ainda sem nenhuma sincronização automática registrada.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private static let formatadorData: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    // MARK: - Filtro de conteúdo

    private var resumoAlbuns: String {
        let n = vm.filtro.albunsSelecionados.count
        return n == 0 ? "Toda a galeria" : "\(n) álbum(ns)"
    }

    private func aplicarFiltro(dataMinima: Date?) {
        vm.salvarFiltro(SyncFiltro(
            albunsSelecionados: vm.filtro.albunsSelecionados,
            dataMinima: dataMinima
        ))
    }

    // MARK: - Consistência do backup

    private func verificarConsistencia() async {
        verificandoConsistencia = true
        erroConsistencia = nil
        resultadoConsistencia = nil
        do {
            resultadoConsistencia = try await vm.verificarConsistencia()
        } catch let erroSync as SyncError {
            erroConsistencia = erroSync.errorDescription
        } catch {
            erroConsistencia = error.localizedDescription
        }
        verificandoConsistencia = false
    }

    private func recopiarAusentes() async {
        guard let ids = resultadoConsistencia, !ids.isEmpty else { return }
        recopiandoAusentes = true
        erroConsistencia = nil
        do {
            try await vm.recopiarItensAusentes(ids)
            resultadoConsistencia = []
        } catch let erroSync as SyncError {
            erroConsistencia = erroSync.errorDescription
        } catch {
            erroConsistencia = error.localizedDescription
        }
        recopiandoAusentes = false
    }

    // MARK: - Adoção do livro-razão

    private func adotarLedger() async {
        adotandoLedger = true
        resultadoAdocao = nil
        do {
            let adotados = try await vm.adotarLedgerDoDestino()
            resultadoAdocao = adotados > 0
                ? "\(adotados) item(ns) reconhecido(s) como já sincronizado(s)."
                : "Nenhum livro-razão novo encontrado na pasta de destino (ou já estava tudo em dia)."
        } catch let erroSync as SyncError {
            resultadoAdocao = erroSync.errorDescription
        } catch {
            resultadoAdocao = error.localizedDescription
        }
        adotandoLedger = false
    }

    // MARK: - Auxiliares

    private func verificarEspaco() async {
        carregandoEspaco = true
        erroEspaco = nil
        do {
            async let livre = vm.espacoLivreDestino()
            async let total = vm.tamanhoTotalBackup()
            async let galeria = vm.tamanhoTotalGaleria()   // não lança erro
            let galeriaBytes = await galeria
            let (livreBytes, totalBytes) = try await (livre, total)
            espacoLivreTexto = StorageInfo.formatar(livreBytes)
            tamanhoBackupTexto = StorageInfo.formatar(totalBytes)
            tamanhoGaleriaTexto = StorageInfo.formatar(galeriaBytes)
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
