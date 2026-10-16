import SwiftUI
import PaperclipMobile

struct SeedGenerationView: View {
    let onGenerate: (Data, Int, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var sensors = SensorEntropyCollector()
    @State private var words = 24
    @State private var method = "system"
    @State private var sides = 6
    @State private var rolls: [Int] = []
    @State private var camera = true
    @State private var microphone = true
    @State private var gyro = true
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error = ""
    private var bits: Int { words == 12 ? 128 : 256 }
    private var required: Int { (try? SeedEntropy.requiredRolls(words: words, sides: sides)) ?? 100 }
    private var source: String { method == "dice" ? "Physical D\(sides) dice" : (method == "sensors" ? "Secure system random + sensors" : "Secure system random") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                WalletBrand()
                Text("Make it yours.\nKeep it secret.").font(.largeTitle.bold())
                Text("Choose where your wallet’s randomness comes from.").foregroundStyle(PaperclipTheme.muted)
                WalletSection("Recovery phrase") {
                    Picker("Phrase length", selection: $words) {
                        Text("12 words").tag(12); Text("24 words").tag(24)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("\(bits) bits").font(.title2.bold()).monospacedDigit()
                        Spacer()
                        Text("BIP39 entropy").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                    }
                    Text("The checksum adds \(bits / 32) bits for error detection, not randomness. The later 512-bit wallet seed does not increase this entropy.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                WalletSection("Entropy source") {
                    sourceRow("system", "Secure system random", "Recommended · Apple’s cryptographic random generator", "lock.shield")
                    Divider()
                    sourceRow("dice", "Roll your own", "Physical D6, D12, or D20 dice", "dice")
                    Divider()
                    sourceRow("sensors", "Add your surroundings", "Camera, microphone, and gyroscope + system random", "waveform")
                }
                if method == "dice" { diceSection }
                if method == "sensors" { sensorSection }
                if method == "system" {
                    WalletSection("How it works") {
                        Text("Paperclip requests \(bits / 8) bytes directly from Apple’s secure random API (SecRandomCopyBytes). If that request fails, generation stops.")
                        Text("BIP39 adds a SHA-256 checksum, then encodes the result as \(words) words. Randomness is generated locally; it is not downloaded from a server or derived from the clock, wallet name, or your account.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                        Text("\(bits) bits is the requested entropy size. Paperclip cannot independently measure the operating system’s internal entropy pool.").font(.caption)
                    }
                }
                Button(action: generate) {
                    HStack { if busy { ProgressView() }; Text("Generate \(words) words"); Image(systemName: "arrow.right") }.frame(maxWidth: .infinity)
                }.buttonStyle(WalletPrimaryButtonStyle()).disabled(!ready || busy)
                Text("Next: write down every word and verify your copy. Keep rolls and sensor inputs private too—they help determine your keys.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                if !error.isEmpty { Text(error).foregroundStyle(PaperclipTheme.orange) }
            }.walletPageContent()
        }.walletPageBackground().navigationTitle("Create your seed").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sensors.clear(); dismiss() }.disabled(busy) } }
            .onChange(of: method) { _, _ in sensors.clear(); rolls.removeAll(); acknowledged = false; error = "" }
            .onChange(of: sides) { _, _ in rolls.removeAll(); acknowledged = false }
            .onChange(of: words) { _, _ in sensors.clear(); acknowledged = false }
            .onChange(of: phase) { _, value in if value == .background { sensors.clear(); rolls.removeAll(); acknowledged = false } }
            .onDisappear { sensors.clear(); rolls.removeAll() }
            .disabled(busy)
    }
    private var ready: Bool {
        method == "system" || (method == "dice" && rolls.count >= required && acknowledged) || (method == "sensors" && sensors.digest != nil && !sensors.collecting)
    }
    private func sourceRow(_ value: String, _ title: String, _ subtitle: String, _ icon: String) -> some View {
        Button { method = value } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(PaperclipTheme.orange).frame(width: 30)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(PaperclipTheme.muted) }
                Spacer()
                Image(systemName: method == value ? "checkmark.circle.fill" : "circle").foregroundStyle(method == value ? PaperclipTheme.orange : PaperclipTheme.muted)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var diceSection: some View {
        WalletSection("Pick your die") {
            HStack(spacing: 12) {
                ForEach([6, 12, 20], id: \.self) { die in
                    Button { sides = die } label: {
                        VStack(spacing: 10) {
                            DieOutline(sides: die).stroke(PaperclipTheme.orange, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round)).frame(height: 62)
                            Text("D\(die)").font(.headline)
                            Text("\((try? SeedEntropy.requiredRolls(words: words, sides: die)) ?? 0) rolls").font(.caption)
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(PaperclipTheme.orange.opacity(sides == die ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(PaperclipTheme.orange.opacity(sides == die ? 0.8 : 0.15)))
                    }.buttonStyle(.plain).accessibilityLabel("D\(die), \((try? SeedEntropy.requiredRolls(words: words, sides: die)) ?? 0) rolls").accessibilityAddTraits(sides == die ? .isSelected : [])
                }
            }
            Text("Roll a fair physical D\(sides) and enter each result in order. Do not invent a sequence or use an online dice roller. Every roll contributes, including extra rolls. Switching phrase length keeps your rolls; changing the die clears them.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
            HStack { Text("\(rolls.count) rolls · \(required) minimum").font(.headline).monospacedDigit(); Spacer(); Button("Undo") { if !rolls.isEmpty { rolls.removeLast() } }.disabled(rolls.isEmpty) }
            ProgressView(value: Double(min(rolls.count, required)), total: Double(required)).tint(PaperclipTheme.orange)
            Text("≈ \(Double(rolls.count) * log2(Double(sides)), specifier: "%.1f") input bits estimated · \(bits)-bit output").font(.caption).monospacedDigit()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: sides == 6 ? 3 : 4), spacing: 10) {
                ForEach(1...sides, id: \.self) { face in
                    Button { rolls.append(face) } label: {
                        Text(String(face)).font(.title3.weight(.semibold)).monospacedDigit().frame(maxWidth: .infinity).frame(height: 46)
                            .background(PaperclipTheme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(rolls.count >= SeedEntropy.maximumDiceRolls).accessibilityLabel("Rolled \(face)")
                }
            }
            if !rolls.isEmpty { Text("Last roll: \(rolls.last!)").font(.caption).privacySensitive() }
            Text(rolls.count >= SeedEntropy.maximumDiceRolls ? "1,000-roll limit reached. All rolls will be used." : (rolls.count >= required ? "Ready when you are. Keep rolling or generate your phrase below." : "Enter at least \(required - rolls.count) more rolls to continue.")).font(.caption).foregroundStyle(PaperclipTheme.muted)
            Toggle("I used fair physical dice and recorded every independent roll accurately.", isOn: $acknowledged).font(.subheadline).tint(PaperclipTheme.orange)
            DisclosureGroup("How dice become seed words") {
                Text("Dice-only mode adds no system randomness. Paperclip hashes the UTF-8 text ‘Paperclip/dice/v1/sides=N’, a newline, and your comma-separated decimal results with SHA-256. It uses the first 16 bytes for 12 words, or all 32 bytes for 24 words. Every recorded roll is hashed before the output is sized—even for 12 words. Extra rolls contribute to the result but cannot increase the phrase beyond its 128- or 256-bit limit. Back up the words.").font(.caption)
                Text("The estimate is rolls × log₂(sides), assuming fair, independent rolls. Hashing cannot make predictable or biased rolls random, and the app cannot verify how you rolled.").font(.caption)
            }
        }
    }
    private var sensorSection: some View {
        VStack(spacing: 24) {
            WalletSection("Choose your sensors") {
                Text("Add local samples to secure system randomness. Choose your sources, then collect for up to 30 seconds.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                Group {
                    Toggle(isOn: $camera) { Label("Camera", systemImage: "camera") }
                    Divider()
                    Toggle(isOn: $microphone) { Label("Microphone", systemImage: "mic") }
                    Divider()
                    Toggle(isOn: $gyro) { Label("Motion", systemImage: "gyroscope") }
                }.tint(PaperclipTheme.orange).disabled(sensors.collecting || sensors.digest != nil)
            }
            WalletSection("Collect samples") {
                Label(sensors.collecting ? "Collecting your surroundings" : (sensors.digest != nil ? "Samples ready" : "Ready to collect"), systemImage: sensors.digest != nil ? "checkmark.circle" : "waveform")
                    .font(.headline).foregroundStyle(PaperclipTheme.orange)
                if sensors.collecting || sensors.digest != nil {
                    HStack { sampleCount("Frames", sensors.counts[0]); Spacer(); sampleCount("Audio", sensors.counts[1]); Spacer(); sampleCount("Motion", sensors.counts[2]) }
                }
                Text("Samples stay on this device and are never saved or uploaded.").font(.subheadline).foregroundStyle(PaperclipTheme.muted)
                if sensors.collecting {
                    Button { sensors.finish() } label: {
                        HStack { ProgressView(); Text(sensors.finishing ? "Finishing…" : "Finish collecting") }.frame(maxWidth: .infinity)
                    }.buttonStyle(WalletPrimaryButtonStyle()).disabled(sensors.finishing)
                } else if sensors.digest != nil {
                    Text("Continue with Generate \(words) words below.").font(.subheadline)
                    Button("Discard and collect again") { sensors.clear() }
                } else {
                    Button { Task { await sensors.start(camera: camera, microphone: microphone, gyro: gyro) } } label: {
                        Label("Start collecting", systemImage: "waveform").frame(maxWidth: .infinity)
                    }.buttonStyle(WalletPrimaryButtonStyle()).disabled(!camera && !microphone && !gyro)
                }
                if !sensors.message.isEmpty { Text(sensors.message).font(.caption).foregroundStyle(PaperclipTheme.muted) }
            }
            WalletSection("Privacy & seed strength") {
                Text("\(bits) bits from secure system randomness").font(.subheadline.weight(.semibold))
                Text("Sensors add input, but their unpredictable entropy cannot be verified. No extra security bits are claimed.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                DisclosureGroup("Sensor measurements") {
                    ForEach(0..<3, id: \.self) { index in
                        let health = sensors.health[index]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(["Camera", "Microphone", "Gyroscope"][index]).font(.headline)
                            Text(health.status).font(.caption).foregroundStyle(health.looksStuck ? PaperclipTheme.orange : PaperclipTheme.muted)
                            Text("\(health.bytes.formatted()) raw bytes sampled · \(health.distinctValues)/256 byte values").font(.caption)
                            if health.bytes > 0 {
                                Text("Empirical min-entropy: \(health.empiricalMinEntropy, specifier: "%.2f") bits/byte (distribution only)").font(.caption)
                                Text("Most common byte: \(health.mostCommonFraction * 100, specifier: "%.1f")% · repeated packets: \(health.repeatedPackets) · longest sampled-byte run: \(health.longestByteRun)").font(.caption)
                            }
                        }
                        if index < 2 { Divider() }
                    }
                    Text("Measured before hashing, with timestamps excluded from motion diagnostics. These checks detect some stuck or repetitive inputs. Correlated or predictable inputs can still score well; this is not a validated cryptographic entropy rate and is never multiplied into a seed-strength claim.").font(.caption).foregroundStyle(PaperclipTheme.muted)
                }
                DisclosureGroup("How samples are mixed") {
                    Text("Camera frames, audio buffers, and gyroscope samples feed a local SHA-256 digest with source tags and lengths. That digest is hashed together with fresh SecRandomCopyBytes output and a Paperclip-specific label. Sensors never replace system randomness. Canceling or leaving the app discards the collection.").font(.caption)
                }
            }
        }
    }
    private func sampleCount(_ label: String, _ count: Int) -> some View {
        VStack(alignment: .leading) { Text(count.formatted()).font(.headline).monospacedDigit(); Text(label).font(.caption).foregroundStyle(PaperclipTheme.muted) }
    }
    private func generate() {
        guard ready, !busy else { return }
        busy = true; error = ""
        Task { @MainActor in
            do {
                let entropy: Data
                if method == "dice" { entropy = try SeedEntropy.dice(rolls, sides: sides, words: words) }
                else if method == "sensors", let digest = sensors.digest { entropy = try SeedEntropy.mix(system: SeedEntropy.system(words: words), sensorDigest: digest, words: words) }
                else { entropy = try SeedEntropy.system(words: words) }
                try await onGenerate(entropy, words, source)
                sensors.clear(); rolls.removeAll(); dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// Small code-drawn outlines keep the dice crisp in both appearance modes.
private struct DieOutline: Shape {
    let sides: Int
    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * size, y: origin.y + y * size) }
        var path = Path()
        func line(_ points: [CGPoint], close: Bool = false) {
            guard let first = points.first else { return }
            path.move(to: first); for p in points.dropFirst() { path.addLine(to: p) }; if close { path.closeSubpath() }
        }
        let top = point(0.5, 0.04), left = point(0.08, 0.27), right = point(0.92, 0.27)
        let bottom = point(0.5, 0.96), lowerLeft = point(0.08, 0.73), lowerRight = point(0.92, 0.73)
        line([top, right, lowerRight, bottom, lowerLeft, left], close: true)
        if sides == 6 {
            let center = point(0.5, 0.51)
            line([left, center, right]); line([center, bottom])
        } else if sides == 12 {
            let a = point(0.5, 0.25), b = point(0.75, 0.43), c = point(0.65, 0.72), d = point(0.35, 0.72), e = point(0.25, 0.43)
            line([a, b, c, d, e], close: true)
            line([top, a]); line([right, b, lowerRight]); line([bottom, c]); line([bottom, d]); line([lowerLeft, e, left])
        } else {
            let a = point(0.5, 0.27), b = point(0.27, 0.7), c = point(0.73, 0.7)
            line([a, b, c], close: true); line([top, a, left, b, lowerLeft]); line([a, right, c, lowerRight]); line([b, bottom, c])
        }
        return path
    }
}
