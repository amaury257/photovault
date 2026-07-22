//
//  KeychainStore.swift
//  PhotoVaultiCloudSync
//
//  Wrapper mínimo sobre o Keychain do iOS. Ao contrário de `UserDefaults` e da
//  pasta Application Support (onde fica o livro-razão), o Keychain SOBREVIVE
//  à remoção/reinstalação do app — desde que o Bundle ID e o Team ID de
//  assinatura continuem os mesmos, o que é o caso normal ao reatualizar via
//  AltStore/SideStore/iloader com a MESMA conta Apple.
//
//  Usado por `SettingsStore` para que as configurações do usuário (pasta de
//  destino, agendamento, filtro etc.) não se percam a cada atualização por
//  sideload — antes desta versão, o iOS tratava algumas atualizações como
//  instalação de um app "novo" e apagava toda a sandbox (UserDefaults e
//  Application Support), fazendo o app esquecer a pasta de destino escolhida
//  e recomeçar o backup do zero.
//

import Foundation
import Security

enum KeychainStore {

    private static let service = "com.photovault.PhotoVault.settings"

    private static func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    static func data(forKey key: String) -> Data? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var resultado: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &resultado)
        guard status == errSecSuccess else { return nil }
        return resultado as? Data
    }

    @discardableResult
    static func set(_ dados: Data, forKey key: String) -> Bool {
        let q = query(for: key)
        let atualizacao: [String: Any] = [kSecValueData as String: dados]

        let statusAtualizacao = SecItemUpdate(q as CFDictionary, atualizacao as CFDictionary)
        if statusAtualizacao == errSecSuccess { return true }
        guard statusAtualizacao == errSecItemNotFound else { return false }

        var novoItem = q
        novoItem[kSecValueData as String] = dados
        // `ThisDeviceOnly`: não sincroniza via iCloud Keychain para outros
        // aparelhos (o bookmark de segurança é específico deste device/pasta
        // escolhida aqui) — só precisa sobreviver a reinstalações NESTE iPhone.
        novoItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(novoItem as CFDictionary, nil) == errSecSuccess
    }

    static func removeObject(forKey key: String) {
        SecItemDelete(query(for: key) as CFDictionary)
    }
}
