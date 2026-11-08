import IlliquidCore
import SwiftUI

/// Brightness, contrast, saturation, gamma and hue for the current video.
/// Changes apply while the sheet is open, including while paused.
struct PictureAdjustmentsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private struct Control: Identifiable {
        let id: String
        let title: String
        let keyPath: WritableKeyPath<VideoAdjustmentState, Double>
    }

    private let controls = [
        Control(id: "brightness", title: "Brightness", keyPath: \.brightness),
        Control(id: "contrast", title: "Contrast", keyPath: \.contrast),
        Control(id: "saturation", title: "Saturation", keyPath: \.saturation),
        Control(id: "gamma", title: "Gamma", keyPath: \.gamma),
        Control(id: "hue", title: "Hue", keyPath: \.hue),
    ]

    private var adjustments: VideoAdjustmentState { model.state.videoAdjustments }

    private var isNeutral: Bool {
        controls.allSatisfy { adjustments[keyPath: $0.keyPath] == 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Picture Adjustments").font(.headline)
            ForEach(controls) { control in
                HStack(spacing: 12) {
                    Text(control.title)
                        .frame(width: 84, alignment: .leading)
                    Slider(value: binding(control.keyPath), in: -100...100, step: 1)
                        .accessibilityIdentifier("illiquid.picture.\(control.id)")
                    Text("\(Int(adjustments[keyPath: control.keyPath]))")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Button {
                        set(control.keyPath, 0)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset \(control.title)")
                    .disabled(adjustments[keyPath: control.keyPath] == 0)
                }
            }
            HStack {
                Button("Reset All") {
                    var reset = adjustments
                    for control in controls { reset[keyPath: control.keyPath] = 0 }
                    model.player.setVideoEqualizer(reset)
                }
                .disabled(isNeutral)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func binding(_ keyPath: WritableKeyPath<VideoAdjustmentState, Double>) -> Binding<Double> {
        Binding(
            get: { adjustments[keyPath: keyPath] },
            set: { set(keyPath, $0) }
        )
    }

    private func set(_ keyPath: WritableKeyPath<VideoAdjustmentState, Double>, _ value: Double) {
        var next = adjustments
        next[keyPath: keyPath] = value.rounded()
        guard next != adjustments else { return }
        model.player.setVideoEqualizer(next)
    }
}
