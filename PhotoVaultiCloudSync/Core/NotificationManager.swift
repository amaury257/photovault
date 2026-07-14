//
//  NotificationManager.swift
//  PhotoVaultiCloudSync
//
//  Notificações locais (não remotas — não exige nenhum servidor push nem
//  entitlement especial) avisando o usuário quando uma sincronização termina,
//  útil sobretudo para o backup em BACKGROUND: sem uma notificação, o usuário
//  não teria como saber que o backup rodou enquanto o app estava fechado.
//
//  Também registra uma categoria com a ação "Ver detalhes", que leva direto
//  à tela de Histórico ao tocar na notificação — sem isso, ela era só
//  informativa.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject {

    static let shared = NotificationManager()

    /// Alternado para `true` quando o usuário toca (na notificação em si, ou
    /// na ação "Ver detalhes") — observado pela `ContentView` para navegar
    /// até o Histórico. Ela mesma zera de volta para `false` após consumir.
    @Published var solicitarAberturaHistorico = false

    private static let categoriaBackupConcluido = "backup_concluido"
    private static let acaoVerHistorico = "ver_historico"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registrarCategorias()
    }

    /// Registra a categoria + ação "Ver detalhes" — precisa ser feito antes
    /// de qualquer notificação ser exibida (chamado no init, cedo o
    /// suficiente mesmo que o app tenha sido aberto pela própria notificação).
    private func registrarCategorias() {
        let acao = UNNotificationAction(
            identifier: Self.acaoVerHistorico,
            title: "Ver detalhes",
            options: []
        )
        let categoria = UNNotificationCategory(
            identifier: Self.categoriaBackupConcluido,
            actions: [acao],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([categoria])
    }

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
        content.categoryIdentifier = Self.categoriaBackupConcluido

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
        content.categoryIdentifier = Self.categoriaBackupConcluido

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

extension NotificationManager: UNUserNotificationCenterDelegate {

    // Sem `willPresent` de propósito: o requisito iOS padrão para um
    // delegate SEM esse método é não exibir banner/som enquanto o app está
    // em primeiro plano — o mesmo comportamento de quando não havia delegate
    // nenhum. Implementá-lo forçando `[.banner, .sound, .badge]` faria toda
    // sincronização MANUAL (o usuário já olhando o status na tela) tocar som
    // e mostrar banner de forma redundante — uma mudança de comportamento
    // que não foi pedida.

    /// Toque na notificação (ação padrão) OU na ação "Ver detalhes": os dois
    /// levam ao Histórico — não há necessidade de distinguir.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == Self.acaoVerHistorico
        else { return }
        await MainActor.run {
            NotificationManager.shared.solicitarAberturaHistorico = true
        }
    }
}
