import SwiftUI

/// Exposure remains reachable without moving the focus point or waiting for a focus overlay.
struct CameraExposureControl: View {
    enum Layout: Equatable {
        case horizontal
        case vertical(valueAtTop: Bool)
    }

    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Degrees that keep the symbols upright when the interface does not rotate.
    var glyphTurn = 0.0
    var layout: Layout = .horizontal
    var trackLength: CGFloat = 184

    var body: some View {
        Group {
            switch layout {
            case .horizontal:
                HStack(spacing: 10) {
                    sunIcon
                        .frame(width: 64, height: 44, alignment: .leading)
                    slider
                    resetButton(width: 64, height: 44, alignment: glyphTurn == 0 ? .trailing : .center)
                }
                .font(.footnote)
                .frame(minHeight: 44)
            case .vertical(let valueAtTop):
                VStack(spacing: 8) {
                    if valueAtTop {
                        resetButton(width: 46, height: 44, alignment: .center)
                        verticalSlider
                        sunIcon.frame(width: 36, height: 28)
                    } else {
                        sunIcon.frame(width: 36, height: 28)
                        verticalSlider
                        resetButton(width: 46, height: 44, alignment: .center)
                    }
                }
                .font(.caption.weight(.medium))
                .frame(width: 46)
            }
        }
        .foregroundStyle(.white)
    }

    private var sunIcon: some View {
        Image(systemName: "sun.max")
            .rotationEffect(.degrees(glyphTurn))
            .accessibilityHidden(true)
    }

    private var slider: some View {
        DefaultSlider(
            value: $value, range: range, defaultValue: 0,
            title: String(localized: "camera.exposure", defaultValue: "Camera exposure"),
            identifier: "camera.exposure", fillOrigin: 0
        )
        .accessibilityValue(String(format: "%+.2f EV", value))
    }

    private var verticalSlider: some View {
        let angle: Double = layout == .vertical(valueAtTop: true) ? -90 : 90
        return slider
            .frame(width: trackLength, height: 32)
            .fixedSize()
            .rotationEffect(.degrees(angle))
            .frame(width: 36, height: trackLength)
            .contentShape(.rect)
    }

    private func resetButton(width: CGFloat, height: CGFloat, alignment: Alignment) -> some View {
        Button { value = 0 } label: {
            Text(String(format: "%+.2f EV", value)).monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .rotationEffect(.degrees(glyphTurn))
                .frame(width: width, height: height, alignment: alignment)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "control.reset_to_default", defaultValue: "Reset to Default"))
        .accessibilityValue(String(format: "%+.2f EV", value))
        .accessibilityIdentifier("camera.exposureReset")
    }
}

#if DEBUG
/// Isolated control fixture; no camera permission or photo library is opened.
struct CameraExposureControlPreview: View {
    @State private var exposure = 0.0
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraExposureControl(value: $exposure, range: -3...3).frame(width: 320)
        }
    }
}
#endif
