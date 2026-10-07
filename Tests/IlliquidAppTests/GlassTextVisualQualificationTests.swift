import AppKit
import Foundation
import IlliquidCore
import SwiftUI
import Testing
@testable import IlliquidApp

/// Opt-in real-window fixture. Cua captures this window while it is held open;
/// ordinary numerical tests do not imply that this visual gate was exercised.
@Suite("Glass text visual qualification", .serialized)
@MainActor
struct GlassTextVisualQualificationTests {
    @Test func unchangedGlassBeforeAndAfter() async throws {
        guard let raw = ProcessInfo.processInfo.environment["ILLIQUID_GLASS_VISUAL_HOLD_SECONDS"],
              let seconds = Double(raw), seconds > 0 else {
            print("NOT RUN: real-window glass font qualification (opt-in)")
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1200, height: 760),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Illiquid — unchanged glass / font color qualification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: GlassTextQualificationSheet())
        window.orderFront(nil)
        defer { window.close() }
        let message = "GLASS_WINDOW pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)\n"
        FileHandle.standardOutput.write(Data(message.utf8))
        try await Task.sleep(for: .seconds(min(seconds, 300)))
        #expect(window.contentView?.bounds.width == 1200)
    }
}

private struct GlassTextQualificationSheet: View {
    private let names = ["Near black", "Middle grey", "White", "Saturated green", "Split black / white", "Bright patch", "Gradient", "Fine texture"]
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Existing font selection").frame(maxWidth: .infinity)
                Text("New font selection · same glass").frame(maxWidth: .infinity)
            }.font(.headline).foregroundStyle(.white).padding(8)
            ForEach(0..<names.count, id: \.self) { index in
                HStack(spacing: 12) {
                    pane(index: index, updated: false)
                    pane(index: index, updated: true)
                }
            }
        }.padding(12).frame(width: 1200, height: 760)
            .background(Color(white: 0.12)).environment(\.playerTheme, .liquidGlass)
    }

    private func pane(index: Int, updated: Bool) -> some View {
        let samples = samples(index)
        let context = AdaptiveTextLegibility(backgrounds: samples, luminanceLift: 0.08)
        let source = samples[samples.count / 2]
        let color = updated
            ? context.resolve(hueSource: source, palette: .softSpectrum, monochrome: false, previous: nil)
            : AdaptiveRainbowTextColor.resolve(hueFrom: source, contrastAgainst: samples, luminanceLift: 0.08)
        let foreground = Color(red: color.red, green: color.green, blue: color.blue)
        let secondary = updated ? context.readableOpacity(for: color, preferred: 0.96) : 0.96
        let tertiary = updated ? context.readableOpacity(for: color, preferred: 0.90) : 0.90
        let mixed = AdaptiveRainbowTextColor.isMixedLuminanceRegion(samples.map { min(1, $0.relativeLuminance + 0.08) })
        let halo = mixed ? (max(color.red, color.green, color.blue) > 0.5
            ? Color.black.opacity(0.82) : Color.white.opacity(0.76)) : .clear
        return ZStack {
            HStack(spacing: 0) {
                ForEach(samples.indices, id: \.self) { i in
                    Color(red: samples[i].red, green: samples[i].green, blue: samples[i].blue)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(names[index]) · Episode 08 — Café / 東京").font(.system(size: 14, weight: .medium)).foregroundStyle(foreground)
                Text("00:12 / 02:34  ·  Audio: English  ·  Subtitles: Français").font(.system(size: 12)).foregroundStyle(foreground.opacity(secondary))
                Text("Secondary details remain readable across the scene").font(.system(size: 11)).foregroundStyle(foreground.opacity(tertiary))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 10)
                .shadow(color: halo, radius: mixed ? 1.4 : 0, y: 0.5)
                .playerOverlaySurface(cornerRadius: 16, role: .sidebar)
                .padding(5)
        }.frame(height: 80).clipped()
    }

    private func samples(_ index: Int) -> [SampledVideoColor] {
        let black = SampledVideoColor(red: 0, green: 0, blue: 0)
        let white = SampledVideoColor(red: 1, green: 1, blue: 1)
        switch index {
        case 0: return Array(repeating: black, count: 24)
        case 1: return Array(repeating: .init(red: 0.48, green: 0.48, blue: 0.48), count: 24)
        case 2: return Array(repeating: white, count: 24)
        case 3: return Array(repeating: .init(red: 0.05, green: 0.85, blue: 0.1), count: 24)
        case 4: return Array(repeating: black, count: 12) + Array(repeating: white, count: 12)
        case 5: return (0..<24).map { (7...10).contains($0) ? white : black }
        case 6: return (0..<24).map { let c = Double($0) / 23; return .init(red: c, green: c, blue: c) }
        default: return (0..<24).map { $0.isMultiple(of: 2) ? black : white }
        }
    }
}
