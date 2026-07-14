//
//  ProvisioningExpiry.swift
//  PhotoVaultiCloudSync
//
//  Lê a data de expiração do perfil de provisionamento embarcado no bundle
//  (`embedded.mobileprovision`) para avisar o usuário ANTES que a assinatura
//  da AltStore expire (Apple ID gratuito: 7 dias) — hoje o único jeito de
//  descobrir é o app simplesmente parar de abrir.
//
//  `embedded.mobileprovision` é um arquivo CMS (assinado), mas o conteúdo
//  plist vai em texto claro no meio do arquivo — não precisamos decodificar
//  a assinatura CMS, só localizar o bloco `<?xml ... </plist>` e extrair a
//  chave `ExpirationDate`. Técnica pública, usada por vários apps sideloaded:
//  https://www.process-one.net/blog/reading-ios-provisioning-profile-in-swift/
//  https://chris-mash.medium.com/knowing-when-your-ios-apps-provisioning-profile-is-going-to-expire-4689d03d0d5
//
//  Falha graciosamente (retorna `nil`) em qualquer etapa — nunca trava o app
//  por causa disso; na pior das hipóteses, simplesmente não mostra o aviso.
//

import Foundation

enum ProvisioningExpiry {

    /// Data de expiração do perfil de provisionamento embarcado, se
    /// conseguirmos localizar e decodificar o arquivo. `nil` em qualquer
    /// falha (arquivo ausente — comum no Simulador — ou formato inesperado).
    static var dataExpiracao: Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let bruto = try? Data(contentsOf: url),
              let texto = String(data: bruto, encoding: .isoLatin1)
        else {
            return nil
        }

        // O conteúdo binário do arquivo (assinatura CMS) pode conter bytes
        // inválidos para UTF-8, mas ISO-Latin-1 sempre decodifica (1 byte =
        // 1 caractere), preservando os marcadores ASCII `<?xml`/`</plist>`
        // que procuramos a seguir.
        guard let inicio = texto.range(of: "<?xml"),
              let fim = texto.range(of: "</plist>")
        else {
            return nil
        }

        let plistTexto = String(texto[inicio.lowerBound..<fim.upperBound])
        guard let plistDados = plistTexto.data(using: .isoLatin1) else { return nil }

        guard let dicionario = try? PropertyListSerialization.propertyList(
            from: plistDados, options: [], format: nil
        ) as? [String: Any] else {
            return nil
        }

        return dicionario["ExpirationDate"] as? Date
    }

    /// Dias inteiros restantes até a expiração (pode ser negativo se já
    /// expirou). `nil` se a data não pôde ser determinada.
    static var diasRestantes: Int? {
        guard let data = dataExpiracao else { return nil }
        let inicio = Calendar.current.startOfDay(for: Date())
        let fim = Calendar.current.startOfDay(for: data)
        return Calendar.current.dateComponents([.day], from: inicio, to: fim).day
    }
}
