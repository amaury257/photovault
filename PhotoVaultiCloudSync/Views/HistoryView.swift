//
//  HistoryView.swift
//  PhotoVaultiCloudSync
//
//  Tela de histórico: lista as execuções de sincronização (fotos e WhatsApp,
//  manuais ou em background) registradas pelo `SyncHistoryStore`. É só um
//  LOG para consulta — não tem relação com os livros-razão que garantem o
//  backup one-way.
//

import SwiftUI

struct HistoryView: View {

    @State private var entradas: [HistoricoEntry] = []
    @State private var carregando = true
    @State private var mostrandoConfirmacaoLimpar = false

    var body: some View {
        Group {
            if carregando {
                ProgressView()
            } else if entradas.isEmpty {
                ContentUnavailableViewCompat()
            } else {
                List(entradas) { entrada in
                    if entrada.tipo == .fotos {
                        NavigationLink {
                            HistoryDetailView(entrada: entrada)
                        } label: {
                            linha(entrada)
                        }
                    } else {
                        linha(entrada)
                    }
                }
            }
        }
        .navigationTitle("Histórico")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !entradas.isEmpty {
                    Button("Limpar", role: .destructive) {
                        mostrandoConfirmacaoLimpar = true
                    }
                }
            }
        }
        .task {
            await carregar()
        }
        .alert("Limpar histórico?", isPresented: $mostrandoConfirmacaoLimpar) {
            Button("Cancelar", role: .cancel) {}
            Button("Limpar", role: .destructive) {
                Task {
                    await SyncHistoryStore.shared.limpar()
                    await carregar()
                }
            }
        } message: {
            Text("Isto só apaga o registro de consulta — não afeta nenhum arquivo já copiado.")
        }
    }

    private func carregar() async {
        entradas = await SyncHistoryStore.shared.todas()
        carregando = false
    }

    private func linha(_ entrada: HistoricoEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entrada.tipo == .fotos ? "photo.on.rectangle.angled" : "message.fill")
                .font(.title3)
                .foregroundStyle(entrada.erroGeral != nil ? .red : (entrada.tipo == .fotos ? .blue : .green))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(entrada.tipo == .fotos ? "Backup de fotos" : "Backup do WhatsApp")
                    .font(.body.weight(.medium))
                if let erroGeral = entrada.erroGeral {
                    Text(erroGeral)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(textoResultado(entrada))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(Self.formatador.string(from: entrada.data))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func textoResultado(_ entrada: HistoricoEntry) -> String {
        if entrada.falhas == 0 {
            return "\(entrada.enviados) enviado(s)"
        }
        return "\(entrada.enviados) enviado(s), \(entrada.falhas) falharam"
    }

    private static let formatador: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

/// `ContentUnavailableView` só existe a partir do iOS 17 — o app tem alvo
/// mínimo iOS 16, então usamos um substituto simples e compatível.
private struct ContentUnavailableViewCompat: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Nenhuma sincronização registrada ainda.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
}
