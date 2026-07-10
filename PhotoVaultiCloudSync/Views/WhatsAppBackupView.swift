//
//  WhatsAppBackupView.swift
//  PhotoVaultiCloudSync
//
//  Tela dedicada ao backup de mídia do WhatsApp — funcionalidade SEPARADA do
//  backup de fotos da galeria, com suas próprias pastas de ORIGEM (uma ou
//  mais — a pasta que o WhatsApp expõe no app Arquivos) e pasta de DESTINO.
//
//  O WhatsApp não permite escolher por conversa/contato — essa informação
//  fica presa no banco de dados interno dele, fora do alcance de qualquer
//  app de terceiros por causa do sandbox do iOS. O "filtro" possível aqui é
//  as próprias pastas de origem que o usuário escolhe (ex.: apontar para
//  "WhatsApp Images" e "WhatsApp Video" separadamente em vez da pasta
//  "Media" inteira).
//

import SwiftUI
import UniformTypeIdentifiers

struct WhatsAppBackupView: View {

    /// Qual pasta o seletor de Arquivos está sendo aberto para escolher.
    ///
    /// Usar UM único seletor com um "alvo" (em vez de dois `.fileImporter`
    /// separados empilhados na mesma view) evita uma instabilidade conhecida
    /// do SwiftUI: múltiplos modificadores de apresentação do mesmo tipo
    /// anexados à mesma view podem fazer só o primeiro (ou nenhum) funcionar.
    private enum AlvoPicker: Identifiable {
        case origem
        case destino
        var id: Self { self }
    }

    @StateObject private var vm = WhatsAppSyncViewModel()

    @State private var alvoPicker: AlvoPicker?
    @State private var erro: String?
    @State private var mostrandoConfirmacaoReset = false
    @State private var resetando = false

    /// Bookmark de um novo destino já escolhido, aguardando confirmação do
    /// usuário (só é pedida quando JÁ havia um destino configurado).
    @State private var destinoPendente: (bookmark: Data, nome: String)?
    @State private var mostrandoConfirmacaoTrocaDestino = false

    /// Espaço em disco (consultado sob demanda — pode ser lento).
    @State private var espacoLivreTexto: String?
    @State private var tamanhoBackupTexto: String?
    @State private var carregandoEspaco = false
    @State private var erroEspaco: String?

    var body: some View {
        Form {
            Section {
                if vm.origens.isEmpty {
                    Text("Nenhuma pasta escolhida ainda.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.origens) { origem in
                        Text(origem.nome)
                    }
                    .onDelete { indices in
                        // Resolve todos os alvos ANTES de remover — remover um
                        // item desloca os índices seguintes no array original.
                        let paraRemover = indices.map { vm.origens[$0] }
                        for origem in paraRemover { vm.removerOrigem(origem) }
                    }
                }
                Button("Adicionar pasta de origem...") {
                    alvoPicker = .origem
                }
            } header: {
                Text("De onde ler (WhatsApp)")
            } footer: {
                Text("Aponte para Arquivos ▸ Neste iPhone ▸ WhatsApp ▸ Media (ou subpastas "
                    + "específicas, como \"WhatsApp Images\", para restringir o que é copiado — "
                    + "o WhatsApp não permite escolher por conversa ou contato). Você pode "
                    + "adicionar mais de uma pasta.")
            }

            Section {
                if let destino = vm.destinoNome {
                    LabeledContent("Pasta escolhida", value: destino)
                } else {
                    Text("Nenhuma pasta escolhida ainda.")
                        .foregroundStyle(.secondary)
                }
                Button(vm.destinoNome == nil ? "Escolher pasta de destino..." : "Alterar pasta de destino...") {
                    alvoPicker = .destino
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
                if let resultado = vm.ultimoResultado, resultado.falhas > 0 {
                    Text("\(resultado.falhas) item(ns) falharam nesta última sincronização.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
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
                if let espacoLivreTexto {
                    LabeledContent("Espaço livre no destino", value: espacoLivreTexto)
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
                .disabled(carregandoEspaco || vm.destinoNome == nil)
                if let erroEspaco {
                    Text(erroEspaco)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Armazenamento")
            } footer: {
                Text("Calcular o tamanho do backup pode demorar em pastas com muitos arquivos.")
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
            isPresented: Binding(
                get: { alvoPicker != nil },
                set: { novoValor in if !novoValor { alvoPicker = nil } }
            ),
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { resultado in
            let alvo = alvoPicker
            switch resultado {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    // Bookmark criado IMEDIATAMENTE — ver aviso em SecurityScopedBookmark
                    // sobre a validade transitória da URL do .fileImporter.
                    let (bookmark, nome) = try SecurityScopedBookmark.criar(para: url)
                    switch alvo {
                    case .origem:
                        vm.adicionarOrigem(bookmark: bookmark, nome: nome)
                    case .destino:
                        if vm.destinoNome != nil {
                            // Já havia um destino: pede confirmação antes de trocar.
                            destinoPendente = (bookmark, nome)
                            mostrandoConfirmacaoTrocaDestino = true
                        } else {
                            vm.aplicarNovoDestino(bookmark: bookmark, nome: nome)
                        }
                    case nil:
                        break
                    }
                    erro = nil
                } catch {
                    erro = "Não foi possível usar essa pasta. Tente novamente."
                }
            case .failure(let error):
                erro = error.localizedDescription
            }
        }
        .alert("Trocar pasta de destino?", isPresented: $mostrandoConfirmacaoTrocaDestino) {
            Button("Cancelar", role: .cancel) { destinoPendente = nil }
            Button("Trocar") {
                if let destinoPendente {
                    vm.aplicarNovoDestino(bookmark: destinoPendente.bookmark, nome: destinoPendente.nome)
                }
                destinoPendente = nil
            }
        } message: {
            Text("Os arquivos já copiados para \"\(vm.destinoNome ?? "")\" permanecem lá. A partir "
                + "de agora, os novos backups vão para \"\(destinoPendente?.nome ?? "")\".")
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
