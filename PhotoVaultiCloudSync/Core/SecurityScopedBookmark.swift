//
//  SecurityScopedBookmark.swift
//  PhotoVaultiCloudSync
//
//  Utilitário compartilhado para criar bookmarks de segurança a partir de uma
//  URL retornada pelo `.fileImporter` (seletor de Arquivos do sistema).
//
//  IMPORTANTE: o acesso concedido pelo `.fileImporter` a uma URL só é
//  garantido durante o ciclo de execução do próprio callback — por isso
//  `criar(para:)` deve ser chamado IMEDIATAMENTE ao receber a URL, nunca
//  depois de uma pausa assíncrona (ex.: aguardando confirmação do usuário em
//  um alerta). Fluxos que precisam de confirmação guardam o BOOKMARK (Data,
//  que não expira) já resolvido aqui, não a URL.
//

import Foundation

enum SecurityScopedBookmark {

    /// Cria o bookmark de segurança e o nome de exibição (último componente
    /// do caminho) de uma pasta escolhida no seletor de Arquivos.
    static func criar(para url: URL) throws -> (bookmark: Data, nome: String) {
        guard url.startAccessingSecurityScopedResource() else {
            throw SyncError.pastaExternaInacessivel
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        return (bookmark, url.lastPathComponent)
    }

    /// Resolve (só para exibição) o nome amigável de um bookmark salvo
    /// anteriormente. Falhas aqui não são fatais — retorna `nil`.
    static func nomeAmigavel(deBookmark bookmarkData: Data) -> String? {
        var estaDesatualizado = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &estaDesatualizado
        ) else {
            return nil
        }
        return url.lastPathComponent
    }
}
