//
//  WhatsAppBackupView.swift
//  PhotoVaultiCloudSync
//
//  Tela informativa sobre o backup de mídia do WhatsApp.
//
//  O WhatsApp para iOS NÃO expõe sua pasta de mídia ao app Arquivos (ao
//  contrário do Android) — não existe pasta alguma para o usuário, ou para
//  este app, selecionar, nem mesmo manualmente pelo Arquivos nativo. Não há
//  API pública no iOS que permita a um app de terceiros ler o container de
//  outro app sem esse compartilhamento explícito por parte dele. Por isso a
//  versão anterior desta tela (seletor de pasta de origem/destino + motor de
//  cópia) foi removida — não tinha como funcionar em nenhum aparelho.
//
//  O caminho real no iOS é o próprio WhatsApp salvar as mídias recebidas na
//  Fototeca do sistema (WhatsApp ▸ Ajustes ▸ Conversas ▸ "Salvar no Álbum
//  da Câmera"). A partir daí, o backup de GALERIA que este app já faz cobre
//  essas mídias automaticamente, sem nenhuma configuração adicional aqui.
//

import SwiftUI

struct WhatsAppBackupView: View {
    var body: some View {
        Form {
            Section {
                Label {
                    Text("O iOS não permite que o PhotoVault (ou qualquer outro app) acesse a "
                        + "pasta de mídia do WhatsApp diretamente — nem o app Arquivos nativo "
                        + "enxerga essa pasta. Não é uma limitação deste app; é uma restrição "
                        + "do sistema.")
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Por que não há um seletor de pasta aqui")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    passo(numero: 1, texto: "Abra o WhatsApp ▸ Ajustes ▸ Conversas.")
                    passo(numero: 2, texto: "Ative \"Salvar no Álbum da Câmera\".")
                    passo(numero: 3, texto: "Pronto — fotos e vídeos recebidos passam a cair na Fototeca do iPhone.")
                }
                .padding(.vertical, 4)
            } header: {
                Text("Como fazer o backup mesmo assim")
            } footer: {
                Text("A partir daí, o backup de fotos normal do PhotoVault (tela principal) já "
                    + "copia essas mídias automaticamente — não precisa de nada extra aqui.")
            }

            Section {
                Text("Vale só para mídia recebida a partir de agora. O que já está só dentro do "
                    + "WhatsApp (antes de ativar a opção) não é alcançado por nenhum app de "
                    + "terceiros. Documentos/PDFs enviados por chat também não entram na "
                    + "Fototeca — só fotos e vídeos.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Limitações")
            }
        }
        .navigationTitle("Backup do WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func passo(numero: Int, texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(numero).")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(texto)
        }
    }
}

#Preview {
    NavigationStack {
        WhatsAppBackupView()
    }
}
