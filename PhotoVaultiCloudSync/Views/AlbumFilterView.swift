//
//  AlbumFilterView.swift
//  PhotoVaultiCloudSync
//
//  Escolha de quais álbuns entram no backup. Vazio = toda a galeria
//  (comportamento padrão). Útil para deixar de fora Screenshots, rajadas
//  descartáveis ou figurinhas do WhatsApp que hoje entram junto sem distinção.
//
//  A data mínima (outro eixo do filtro) fica em SettingsView — aqui é só a
//  parte de álbuns, que precisa da própria tela por causa da lista.
//

import SwiftUI

struct AlbumFilterView: View {

    @EnvironmentObject private var vm: SyncViewModel

    @State private var albuns: [AlbumInfo] = []
    @State private var selecionados: Set<String> = []
    @State private var carregando = true

    var body: some View {
        List {
            Section {
                Button {
                    selecionados.removeAll()
                } label: {
                    HStack {
                        Text("Toda a galeria")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selecionados.isEmpty {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            } footer: {
                Text("Sem nenhum álbum marcado abaixo, o backup considera a galeria inteira — "
                    + "comportamento padrão.")
            }

            if carregando {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if albuns.isEmpty {
                Section {
                    Text("Nenhum álbum encontrado.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(albuns) { album in
                        Button {
                            if selecionados.contains(album.id) {
                                selecionados.remove(album.id)
                            } else {
                                selecionados.insert(album.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.titulo)
                                        .foregroundStyle(.primary)
                                    Text("\(album.quantidade) item(ns)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selecionados.contains(album.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Álbuns")
                } footer: {
                    Text("Marque um ou mais para restringir o backup só a eles. Um item presente "
                        + "em mais de um álbum marcado entra uma única vez.")
                }
            }
        }
        .navigationTitle("Álbuns no backup")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albuns = await vm.listarAlbuns()
            selecionados = Set(vm.filtro.albunsSelecionados)
            carregando = false
        }
        .onDisappear {
            // Compara como conjuntos: `Array(selecionados)` não tem ordem
            // garantida, então comparar o `SyncFiltro` (que guarda um Array)
            // direto poderia achar "mudou" mesmo com a MESMA seleção,
            // disparando uma gravação e um refresh à toa a cada vez que a
            // tela fecha.
            guard Set(vm.filtro.albunsSelecionados) != selecionados else { return }
            vm.salvarFiltro(SyncFiltro(
                albunsSelecionados: Array(selecionados),
                dataMinima: vm.filtro.dataMinima
            ))
        }
    }
}

#Preview {
    NavigationStack {
        AlbumFilterView()
            .environmentObject(SyncViewModel())
    }
}
