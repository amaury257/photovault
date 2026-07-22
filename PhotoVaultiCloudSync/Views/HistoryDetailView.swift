//
//  HistoryDetailView.swift
//  PhotoVaultiCloudSync
//
//  Detalhe de uma entrada do Histórico: mostra em grade as fotos/vídeos que
//  foram efetivamente copiados NAQUELA execução (`HistoricoEntry.caminhosRelativos`),
//  lendo os arquivos diretamente da pasta de destino do backup — não da galeria.
//  Por isso continua funcionando mesmo que o usuário já tenha apagado a foto
//  original da galeria (o próprio objetivo do backup one-way).
//
//  Miniaturas via QLThumbnailGenerator (funciona para foto e vídeo, sem
//  carregar o arquivo inteiro em memória) e visualização em tela cheia via
//  QLPreviewController (permite arrastar entre os itens, zoom e compartilhar).
//

import SwiftUI
import UIKit
import QuickLook
import QuickLookThumbnailing

struct HistoryDetailView: View {

    let entrada: HistoricoEntry

    /// Um arquivo do backup resolvido para uma URL concreta na pasta de destino.
    private struct ItemBackup: Identifiable {
        let id: String   // o próprio caminho relativo já é único dentro da entrada
        let url: URL
    }

    @State private var itens: [ItemBackup] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var indisponiveis: Set<String> = []
    @State private var solicitados: Set<String> = []
    @State private var erroAcesso: String?
    @State private var carregando = true
    @State private var itemSelecionadoIndex: Int?

    /// URL da pasta de destino com o acesso de segurança (bookmark externo)
    /// mantido aberto durante toda a vida da tela — necessário para pastas
    /// externas escolhidas via seletor de Arquivos.
    @State private var pastaDestino: URL?

    private let colunas = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 3)]

    var body: some View {
        Group {
            if carregando {
                ProgressView()
            } else if let erroAcesso {
                mensagem(erroAcesso, icone: "exclamationmark.triangle")
            } else if itens.isEmpty {
                mensagem(
                    "Nenhuma foto registrada para este backup.\nIsso é normal em execuções antigas, "
                        + "de antes desta tela existir.",
                    icone: "photo.badge.exclamationmark"
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: colunas, spacing: 3) {
                        ForEach(Array(itens.enumerated()), id: \.element.id) { index, item in
                            celula(item)
                                .onTapGesture { itemSelecionadoIndex = index }
                        }
                    }
                    .padding(3)
                }
            }
        }
        .navigationTitle("Fotos do backup")
        .navigationBarTitleDisplayMode(.inline)
        .task { await carregar() }
        .onDisappear {
            pastaDestino?.stopAccessingSecurityScopedResource()
        }
        .fullScreenCover(isPresented: Binding(
            get: { itemSelecionadoIndex != nil },
            set: { if !$0 { itemSelecionadoIndex = nil } }
        )) {
            QuickLookPreview(urls: itens.map(\.url), indiceInicial: itemSelecionadoIndex ?? 0)
                .ignoresSafeArea()
        }
    }

    // MARK: - Carregamento

    private func carregar() async {
        let folderName = SettingsStore.string(forKey: SyncConfig.DefaultsKey.folderName)
            ?? SyncConfig.nomePastaPadrao
        let engine = PhotoSyncEngine(tracker: PhotoTracker())

        let destino: URL
        do {
            destino = try await engine.pastaDestinoParaLeitura(folderName: folderName)
        } catch let erro as SyncError {
            erroAcesso = erro.errorDescription ?? "Não foi possível acessar a pasta do backup."
            carregando = false
            return
        } catch {
            erroAcesso = "Não foi possível acessar a pasta do backup."
            carregando = false
            return
        }

        guard destino.startAccessingSecurityScopedResource() else {
            erroAcesso = "Sem permissão para acessar a pasta do backup. "
                + "Confira a pasta escolhida em Configurações."
            carregando = false
            return
        }
        pastaDestino = destino

        itens = entrada.caminhosRelativos.map { caminho in
            ItemBackup(id: caminho, url: destino.appendingPathComponent(caminho))
        }
        carregando = false
    }

    // MARK: - Célula da grade

    private func celula(_ item: ItemBackup) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
            if let imagem = thumbnails[item.id] {
                Image(uiImage: imagem)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if indisponiveis.contains(item.id) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .contentShape(Rectangle())
        .task { await solicitarThumbnail(item) }
    }

    /// Gera a miniatura sob demanda, na primeira vez que a célula aparece —
    /// evita disparar centenas de gerações de uma vez em backups grandes.
    private func solicitarThumbnail(_ item: ItemBackup) async {
        guard !solicitados.contains(item.id) else { return }
        solicitados.insert(item.id)

        let tamanho = CGSize(width: 200, height: 200)
        let escala = UIScreen.main.scale
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url, size: tamanho, scale: escala, representationTypes: .thumbnail
        )

        do {
            let representacao = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnails[item.id] = representacao.uiImage
        } catch {
            // Arquivo removido/movido manualmente da pasta de destino depois
            // do backup, ou ainda baixando do provedor de nuvem — não é erro
            // fatal da tela, só mostra o item como indisponível.
            indisponiveis.insert(item.id)
        }
    }

    private func mensagem(_ texto: String, icone: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icone)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(texto)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Visualização em tela cheia (QuickLook)

/// Wrapper de `QLPreviewController` — permite abrir num índice específico e
/// arrastar entre todos os itens do backup, com zoom e compartilhamento
/// nativos do sistema.
private struct QuickLookPreview: UIViewControllerRepresentable {
    let urls: [URL]
    let indiceInicial: Int

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = indiceInicial
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(urls: urls)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        init(urls: [URL]) { self.urls = urls }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            urls[index] as NSURL
        }
    }
}

#Preview {
    NavigationStack {
        HistoryDetailView(entrada: HistoricoEntry(
            tipo: .fotos, data: Date(), enviados: 0, falhas: 0
        ))
    }
}
