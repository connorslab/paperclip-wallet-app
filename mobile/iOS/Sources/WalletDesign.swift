import SwiftUI

// Colors match the Paperclip web wallet.
enum PaperclipTheme {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    static let navy = adaptive(light: 0xF2F5FA, dark: 0x111C2E)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x1A293E)
    static let orange = adaptive(light: 0xB93C0C, dark: 0xF56835)
    static let muted = adaptive(light: 0x4B5C73, dark: 0xAFBDD1)
}

struct WalletCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .modifier(GlassCardSurface())
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
            .overlay(Capsule().stroke(.primary.opacity(0.12)))
    }
}

struct WalletBrand: View {
    var body: some View {
        HStack(spacing: 12) {
            Image("PaperclipLogo").resizable().scaledToFit()
                .frame(width: 48, height: 48).accessibilityLabel("Paperclip Pool")
            VStack(alignment: .leading, spacing: 3) {
                Text("PAPERCLIP").font(.headline).tracking(3)
                Text("POOL · XBT WALLET").font(.caption2).tracking(2).foregroundStyle(PaperclipTheme.muted)
            }
            Spacer()
        }
    }
}

struct WalletSection<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        WalletCard {
            if let title { Text(title).font(.headline).foregroundStyle(PaperclipTheme.muted) }
            content
        }
    }
}

private struct GlassCardSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            content.glassEffect(.regular.tint(PaperclipTheme.panel.opacity(0.7)), in: RoundedRectangle(cornerRadius: 26))
        } else { fallback(content) }
        #else
        fallback(content)
        #endif
    }
    private func fallback(_ content: Content) -> some View {
        content.background(PaperclipTheme.panel.gradient, in: RoundedRectangle(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(.primary.opacity(0.09)))
    }
}

struct WalletNavigationRow: View {
    let title: String
    let subtitle: String
    let icon: String
    init(_ title: String, subtitle: String, icon: String) { self.title = title; self.subtitle = subtitle; self.icon = icon }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(PaperclipTheme.orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(PaperclipTheme.muted)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(PaperclipTheme.muted)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct WalletInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.padding(12)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.10)))
    }
}
