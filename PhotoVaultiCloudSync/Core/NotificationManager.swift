//
//  NotificationManager.swift
//  PhotoVaultiCloudSync
//
//  Notificações locais (não remotas — não exige nenhum servidor push nem
//  entitlement especial) avisando o usuário quando uma sincronização termina,
//  útil sobretudo para o backup em BACKGROUND: sem uma notificação, o usuário
//  não teria como saber que o backup rodou enquanto o app estava fechado.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    private init() {}

    /// Solicita autorização para exibir notificações. Chamado uma vez no
    /// lançamento do app; se o usuário negar, `notificar` simplesmente não
    /// exibe nada (falha silenciosa — não é um erro do backup em si).
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Notifica a conclusão de uma sincronização (fotos ou WhatsApp).
    ///
    /// Não notifica quando não há nada de novo (0 enviados e 0 falhas) para
    /// evitar ruído em sincronizações manuais repetidas sem itens pendentes.
    func notificarConclusao(tipo: HistoricoEntry.Tipo, resultado: ResultadoSync) async {
        guard resultado.enviados > 0 || resultado.falhas > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = tipo == .fotos ? "Backup de fotos concluído" : "Backup do WhatsApp concluído"
        content.body = Self.corpoMensagem(resultado)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // dispara imediatamente
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Notifica uma falha irrecuperável (ex.: permissão negada, pasta inacessível).
    func notificarFalha(tipo: HistoricoEntry.Tipo, mensagem: String) async {
        let content = UNMutableNotificationContent()
        content.title = tipo == .fotos ? "Falha no backup de fotos" : "Falha no backup do WhatsApp"
        content.body = mensagem
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func corpoMensagem(_ resultado: ResultadoSync) -> String {
        if resultado.falhas == 0 {
            return "\(resultado.enviados) novo(s) item(ns) copiado(s)."
        }
        return "\(resultado.enviados) copiado(s), \(resultado.falhas) falharam."
    }
}
