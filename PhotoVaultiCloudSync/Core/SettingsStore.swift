//
//  SettingsStore.swift
//  PhotoVaultiCloudSync
//
//  Fachada para as configurações do usuário (pasta de destino, agendamento,
//  filtro de conteúdo, formato de exportação, escopo de compartilhados): lê e
//  escreve no Keychain (via `KeychainStore`), que sobrevive a reinstalações —
//  diferente de `UserDefaults`, apagado sempre que o iOS trata uma
//  atualização por sideload como instalação de um app "novo".
//
//  MIGRAÇÃO AUTOMÁTICA: na primeira leitura de cada chave depois desta
//  versão, se o Keychain ainda não tiver valor mas existir um valor legado em
//  `UserDefaults` (de uma instalação anterior a esta correção), ele é copiado
//  para o Keychain e removido de `UserDefaults` — não é preciso o usuário
//  reconfigurar nada ao atualizar para esta versão.
//
//  Chaves de fora daqui (`lastSyncDate`, `pendingUploadRelativePaths`)
//  permanecem em `UserDefaults` de propósito: são estado operacional/
//  transitório, não preferência do usuário — perdê-las não causa perda de
//  backup nem exige reconfiguração, só reseta um contador de exibição ou a
//  fila de reverificação de upload no iCloud.
//

import Foundation

enum SettingsStore {

    // MARK: - Data

    static func data(forKey key: String) -> Data? {
        if let valor = KeychainStore.data(forKey: key) { return valor }
        guard let legado = UserDefaults.standard.data(forKey: key) else { return nil }
        KeychainStore.set(legado, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return legado
    }

    static func set(_ valor: Data, forKey key: String) {
        KeychainStore.set(valor, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - String

    static func string(forKey key: String) -> String? {
        if let dados = KeychainStore.data(forKey: key), let texto = String(data: dados, encoding: .utf8) {
            return texto
        }
        guard let legado = UserDefaults.standard.string(forKey: key) else { return nil }
        set(legado, forKey: key)
        return legado
    }

    static func set(_ valor: String, forKey key: String) {
        KeychainStore.set(Data(valor.utf8), forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Bool (nil = nenhum valor salvo, nem no Keychain nem legado)

    static func bool(forKey key: String) -> Bool? {
        if let dados = KeychainStore.data(forKey: key), let byte = dados.first {
            return byte != 0
        }
        guard let legado = UserDefaults.standard.object(forKey: key) as? Bool else { return nil }
        set(legado, forKey: key)
        return legado
    }

    static func set(_ valor: Bool, forKey key: String) {
        KeychainStore.set(Data([valor ? 1 : 0]), forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Int

    static func integer(forKey key: String) -> Int? {
        if let dados = KeychainStore.data(forKey: key),
           let texto = String(data: dados, encoding: .utf8),
           let valor = Int(texto) {
            return valor
        }
        guard let legado = UserDefaults.standard.object(forKey: key) as? Int else { return nil }
        set(legado, forKey: key)
        return legado
    }

    static func set(_ valor: Int, forKey key: String) {
        KeychainStore.set(Data(String(valor).utf8), forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Int64

    static func int64(forKey key: String) -> Int64? {
        if let dados = KeychainStore.data(forKey: key),
           let texto = String(data: dados, encoding: .utf8),
           let valor = Int64(texto) {
            return valor
        }
        guard let legado = UserDefaults.standard.object(forKey: key) as? Int64 else { return nil }
        set(legado, forKey: key)
        return legado
    }

    static func set(_ valor: Int64, forKey key: String) {
        KeychainStore.set(Data(String(valor).utf8), forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    // MARK: - Remoção

    static func removeObject(forKey key: String) {
        KeychainStore.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
}
