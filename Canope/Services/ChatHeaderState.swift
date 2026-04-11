import Foundation

@MainActor
struct ChatHeaderState {
    let showsProviderIcon: Bool
    let visibleStatusBadges: [ChatStatusBadge]
    let turnCountLabel: String?

    init<Provider: HeadlessChatProviding>(provider: Provider, usesCodexVisualStyle: Bool) {
        self.showsProviderIcon = !usesCodexVisualStyle
        if usesCodexVisualStyle {
            self.visibleStatusBadges = provider.chatStatusBadges.filter { badge in
                switch badge.kind {
                case .connected, .mcpOkay:
                    return false
                default:
                    return true
                }
            }
        } else {
            self.visibleStatusBadges = provider.chatStatusBadges
        }
        if provider.session.turns > 0 {
            self.turnCountLabel = "\(provider.session.turns) turns"
        } else {
            self.turnCountLabel = nil
        }
    }
}
