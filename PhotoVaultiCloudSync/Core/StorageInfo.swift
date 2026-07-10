//
//  StorageInfo.swift
//  PhotoVaultiCloudSync
//
//  Utilitários de espaço em disco: espaço livre no volume de uma pasta de
//  destino e tamanho total já ocupado pelo backup. Usados sob demanda pela UI
//  (Configurações / Backup do WhatsApp) — nunca chamados automaticamente, pois
//  enumerar uma pasta grande pode ser lento.
//

import Foundation

enum StorageInfo {

    /// Espaço livre (em bytes) no volume que contém `url`, considerando o uso
    /// "importante" do app (mesma métrica usada pelo sistema para decidir se
    /// há espaço suficiente para operações relevantes ao usuário).
    static func espacoLivre(em url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    /// Soma recursivamente o tamanho (em bytes) de todos os arquivos regulares
    /// dentro de `url`. Pode ser lento em pastas grandes — chamar sob demanda.
    static func tamanhoTotal(em url: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerador = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        for case let itemURL as URL in enumerador {
            let valores = try? itemURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if valores?.isRegularFile == true {
                total += Int64(valores?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Formata um total de bytes em texto amigável (ex.: "1,2 GB"), usando o
    /// estilo de arquivo padrão do sistema.
    static func formatar(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
