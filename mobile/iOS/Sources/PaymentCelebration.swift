import SwiftUI

/// A finite, decorative celebration. Only verified completion may show it.
struct PaymentCelebration: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@State private var start: Date?
	@State private var finished = false
	@State private var appeared = false

	var body: some View {
		ZStack {
			if !reduceMotion && !finished, let start {
				TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
					Canvas { context, size in
						let elapsed = timeline.date.timeIntervalSince(start)
						let progress = min(1, max(0, elapsed / 1.8))
						for index in 0..<44 {
							let angle = Double(index) * 2.399963
							let reach = Double(min(size.width, size.height)) * (0.26 + Double(index % 5) * 0.045)
							let distance = reach * (1 - pow(1 - progress, 3))
							let center = CGPoint(x: size.width / 2 + cos(angle) * distance, y: size.height / 2 + sin(angle) * distance + 28 * progress * progress)
							let radius = CGFloat(2 + index % 3) * (1 - progress * 0.6)
							let shape = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
							context.opacity = (1 - progress) * 0.95
							context.fill(shape, with: .color(index.isMultiple(of: 3) ? .primary : PaperclipTheme.orange))
						}
					}
				}
			}
			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 64, weight: .semibold))
				.foregroundStyle(PaperclipTheme.orange)
				.scaleEffect(reduceMotion || appeared ? 1 : 0.75)
				.animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.35), value: appeared)
		}
		.frame(maxWidth: .infinity).frame(height: 180)
		.accessibilityHidden(true).allowsHitTesting(false)
		.onDisappear { finished = true }
		.task {
			appeared = true
			guard !reduceMotion, start == nil else { return }
			start = Date()
			do { try await Task.sleep(for: .seconds(2)) } catch { return }
			finished = true
		}
	}
}
