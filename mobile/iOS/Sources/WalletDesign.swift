import SwiftUI
import PaperclipMobile

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

/// Shared backdrop keeps the same restrained orange glow across navigation and sheets.
struct WalletBackdrop: View {
    var body: some View {
        ZStack {
            PaperclipTheme.navy
            RadialGradient(colors: [PaperclipTheme.orange.opacity(0.09), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}

struct WalletPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 14)
            .foregroundStyle(.white)
            .background((enabled ? PaperclipTheme.orange : Color.gray).gradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .shadow(color: PaperclipTheme.orange.opacity(enabled ? 0.15 : 0), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.18), value: configuration.isPressed)
    }
}

/// A brief press response for navigation rows; native navigation owns the page transition.
struct WalletNavigationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.12), value: configuration.isPressed)
    }
}

struct WalletCard<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var inset: CGFloat = 20
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(inset)
            .modifier(GlassCardSurface())
            .overlay {
                RoundedRectangle(cornerRadius: 26).stroke(
                    LinearGradient(colors: [PaperclipTheme.orange.opacity(0.18), .primary.opacity(0.05), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
            .opacity(appeared || reduceMotion ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
            .onAppear {
                guard !appeared else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.12)) { appeared = true }
            }
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
            if let title {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(PaperclipTheme.orange.opacity(0.8)).frame(width: 3, height: 14).accessibilityHidden(true)
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PaperclipTheme.muted)
                }
            }
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
    @Environment(\.dynamicTypeSize) private var textSize
    let title: String
    let subtitle: String
    let icon: String
    init(_ title: String, subtitle: String, icon: String) { self.title = title; self.subtitle = subtitle; self.icon = icon }
    var body: some View {
        HStack(spacing: 14) {
            if !textSize.isAccessibilitySize {
            Image(systemName: icon).font(.title3).foregroundStyle(PaperclipTheme.orange)
                .frame(width: 40, height: 40).background(PaperclipTheme.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.caption).foregroundStyle(PaperclipTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(PaperclipTheme.muted).accessibilityHidden(true)
        }.padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct WalletInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 14).padding(.vertical, 13)
            .background(PaperclipTheme.navy.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PaperclipTheme.muted.opacity(0.22)))
    }
}

/// Display-only grouping; payment entry and serialized amounts remain unchanged.
struct WalletBalanceNumber: View {
    let sats: UInt64?
    let unit: BitcoinUnit
    var hidden = false

    private var styled: AttributedString {
        guard !hidden else { return AttributedString("••••••") }
        guard let sats else { return AttributedString("—") }
        let whole = String(unit == .sats ? sats : sats / 100_000_000)
        var digits = ""
        for (index, digit) in whole.enumerated() {
            if index > 0 && (whole.count - index).isMultiple(of: 3) { digits += "\u{202F}" }
            digits.append(digit)
        }
        if unit == .xbt {
            let remainder = String(sats % 100_000_000)
            let fraction = String(repeating: "0", count: 8 - remainder.count) + remainder
            digits += "."
            for (index, digit) in fraction.enumerated() {
                if index == 2 || index == 5 { digits += "\u{202F}" }
                digits.append(digit)
            }
        }
        var result = AttributedString()
        var significant = false
        for character in digits {
            if character >= "1" && character <= "9" { significant = true }
            var part = AttributedString(String(character))
            part.foregroundColor = significant ? Color.primary : PaperclipTheme.muted
            result.append(part)
        }
        return result
    }

    var body: some View {
        Text(styled).monospacedDigit()
            .accessibilityLabel(hidden ? "Balance hidden" : unit.display(sats))
    }
}

// Limit the whole content column, never individual cards inside a row.
extension View {
    func walletPageContent(maxWidth: CGFloat = 760) -> some View {
        self.frame(maxWidth: maxWidth).padding(.horizontal, 22).padding(.top, 12)
            .padding(.bottom, 22).frame(maxWidth: .infinity)
    }
    func walletPageBackground() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { WalletBackdrop().ignoresSafeArea() }
    }
}

/// Reflows the same view identities when a window resizes, preserving form and
/// navigation state. The breakpoint is based on usable content width, not device type.
struct WalletColumns<Primary: View, Secondary: View>: View {
	@Environment(\.dynamicTypeSize) private var textSize
	let spacing: CGFloat
	let primary: Primary
	let secondary: Secondary

	init(spacing: CGFloat = 22, @ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
		self.spacing = spacing
		self.primary = primary()
		self.secondary = secondary()
	}

	var body: some View {
		WalletColumnLayout(stack: textSize.isAccessibilitySize, spacing: spacing) {
			VStack(alignment: .leading, spacing: spacing) { primary }.frame(maxWidth: .infinity)
			VStack(alignment: .leading, spacing: spacing) { secondary }.frame(maxWidth: .infinity)
		}
	}
}

private struct WalletColumnLayout: Layout {
	let stack: Bool
	let spacing: CGFloat

	private func columns(_ width: CGFloat) -> Bool { !stack && width >= 700 }

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? 700
		let wide = columns(width)
		let itemWidth = wide ? (width - spacing) / 2 : width
		let heights = subviews.map { $0.sizeThatFits(.init(width: itemWidth, height: nil)).height }
		return CGSize(width: width, height: wide ? (heights.max() ?? 0) : heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		let wide = columns(bounds.width)
		let width = wide ? (bounds.width - spacing) / 2 : bounds.width
		var origin = bounds.origin
		for view in subviews {
			let size = view.sizeThatFits(.init(width: width, height: nil))
			view.place(at: origin, anchor: .topLeading, proposal: .init(width: width, height: size.height))
			if wide { origin.x += width + spacing } else { origin.y += size.height + spacing }
		}
	}
}

/// Orientation-independent progress for reviewable flows; not a payment outcome.
struct WalletFlowProgress: View {
	let steps: [String]
	let current: Int
	@Environment(\.dynamicTypeSize) private var textSize
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	var body: some View {
		let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
		layout {
			ForEach(steps.indices, id: \.self) { index in
				HStack(spacing: 7) {
					Text(String(index + 1)).font(.caption.bold())
						.frame(width: 24, height: 24)
						.background(index == current ? PaperclipTheme.orange.opacity(0.18) : PaperclipTheme.muted.opacity(0.08), in: Circle())
					Text(steps[index]).font(.caption.weight(index == current ? .bold : .regular))
				}.foregroundStyle(index == current ? PaperclipTheme.orange : PaperclipTheme.muted)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}.accessibilityElement(children: .ignore)
			.accessibilityLabel("Step \(current + 1) of \(steps.count): \(steps.indices.contains(current) ? steps[current] : "")")
			.animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: current)
	}
}

/// The same amount-first review across hot wallets, node payments and QR signers.
struct PaymentReviewHero: View {
    let amount: String
    let source: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(PaperclipTheme.orange)
                .frame(width: 60, height: 60)
                .background(PaperclipTheme.orange.opacity(0.12), in: Circle())
                .rotationEffect(.degrees(appeared || reduceMotion ? 0 : -12))
                .scaleEffect(appeared || reduceMotion ? 1 : 0.8)
                .accessibilityHidden(true)
            Text("Recipient receives").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            Text(amount).font(.largeTitle.bold()).monospacedDigit()
                .multilineTextAlignment(.center).accessibilityIdentifier("payment-recipient-amount")
            Text("From \(source)").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.36, bounce: 0.22)) { appeared = true }
            }
    }
}

/// Amounts wrap below their labels at large text sizes or narrow widths.
struct WalletReviewDetail: View {
    let title: String
    let value: String
    var emphasized = false
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        ViewThatFits(in: .horizontal) {
            if !textSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(title).foregroundStyle(PaperclipTheme.muted).fixedSize()
                    Spacer(minLength: 0)
                    Text(value).monospacedDigit().fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(PaperclipTheme.muted)
                Text(value).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.font(emphasized ? .headline : .subheadline)
            .foregroundStyle(.primary).padding(.vertical, 4)
            .accessibilityElement(children: .combine)
    }
}
