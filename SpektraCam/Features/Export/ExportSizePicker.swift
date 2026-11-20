import SwiftUI

/// Export size options ordered from highest to lowest resolution, left to right.
struct ExportSizePicker: View {
    @Binding var size: PhotoExporter.Size
    /// The edit has a sized paper layout, so a print resolution means something.
    var allowsPrint = false
    private enum Mode: Hashable { case original, longEdge, percent, print }
    private var mode: Mode {
        switch size {
        case .original: .original
        case .longEdge: .longEdge
        case .percent: .percent
        case .print: allowsPrint ? .print : .original
        }
    }

    var body: some View {
        Picker(String(localized: "export.size", defaultValue: "Size"), selection: Binding(get: { mode }, set: { next in
            switch next {
            case .original: size = .original
            case .longEdge: size = .longEdge(2048)
            case .percent: size = .percent(75)
            case .print: size = .print(ppi: 300)
            }
        })) {
            Text(String(localized: "export.size.original", defaultValue: "Original")).tag(Mode.original)
            Text(String(localized: "export.size.long_edge", defaultValue: "Long edge")).tag(Mode.longEdge)
            Text(String(localized: "export.size.percent", defaultValue: "Percent")).tag(Mode.percent)
            if allowsPrint { Text(String(localized: "export.size.print", defaultValue: "Print")).tag(Mode.print) }
        }
        .pickerStyle(.segmented).accessibilityIdentifier("export.size")
        switch size {
        case .original:
            EmptyView()
        case .longEdge(let pixels):
            let choices =
                PhotoExporter.Size.longEdgePresets.contains(pixels)
                ? PhotoExporter.Size.longEdgePresets
                : (PhotoExporter.Size.longEdgePresets + [pixels]).sorted(by: >)
            Picker(String(localized: "export.size.long_edge", defaultValue: "Long edge"),
                   selection: Binding(get: { pixels }, set: { size = .longEdge($0) })) {
                ForEach(choices, id: \.self) { Text(verbatim: "\($0) px").tag($0) }
            }
            .accessibilityIdentifier("export.size.longEdge")
        case .percent(let percent):
            let choices =
                PhotoExporter.Size.percentPresets.contains(percent)
                ? PhotoExporter.Size.percentPresets
                : (PhotoExporter.Size.percentPresets + [percent]).sorted(by: >)
            Picker(String(localized: "export.size.percent", defaultValue: "Percent"),
                   selection: Binding(get: { percent }, set: { size = .percent($0) })) {
                ForEach(choices, id: \.self) { Text(verbatim: "\($0) %").tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("export.size.percent")
        case .print(let ppi):
            let choices =
                PhotoExporter.Size.ppiPresets.contains(ppi)
                ? PhotoExporter.Size.ppiPresets
                : (PhotoExporter.Size.ppiPresets + [ppi]).sorted(by: >)
            Picker(String(localized: "export.size.print", defaultValue: "Print"),
                   selection: Binding(get: { ppi }, set: { size = .print(ppi: $0) })) {
                ForEach(choices, id: \.self) { Text(verbatim: "\($0) ppi").tag($0) }
            }
            .pickerStyle(.segmented).accessibilityIdentifier("export.size.print")
        }
    }
    /// "6000 × 4000 px · 24.0 MP"
    static func describe(width: Int, height: Int) -> String {
        let megapixels = (Double(width) * Double(height) / 1_000_000).formatted(.number.precision(.fractionLength(1)))
        return "\(width) × \(height) px · \(megapixels) MP"
    }
}
