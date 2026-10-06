import SwiftUI

// Colors match the Paperclip web wallet.
enum PaperclipTheme {
    static let navy = Color(red: 17/255, green: 28/255, blue: 46/255)
    static let panel = Color(red: 26/255, green: 41/255, blue: 62/255)
    static let orange = Color(red: 245/255, green: 104/255, blue: 53/255)
    static let muted = Color(red: 175/255, green: 189/255, blue: 209/255)
}

struct WalletCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(PaperclipTheme.panel.gradient, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.09)))
    }
}

struct GlassAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.padding(14).glassEffect(.regular.tint(PaperclipTheme.orange.opacity(0.12)).interactive(), in: .capsule)
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content.padding(14).background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12)))
    }
}

struct WalletBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperclip").font(.title2.bold()).foregroundStyle(PaperclipTheme.navy)
                .frame(width: 44, height: 44).background(PaperclipTheme.orange, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text("PAPERCLIP").font(.headline).tracking(3)
                Text("POOL · XBT WALLET").font(.caption2).tracking(2).foregroundStyle(PaperclipTheme.muted)
            }
            Spacer()
        }
    }
}
