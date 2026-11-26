import SwiftUI
import UIKit

/// A feature-local workspace; the owning editor retains the session, history and export lifecycle.
struct DarkroomView: View {
    let image: UIImage
    /// Stacked puts the controls under the print; side by side puts them in a column beside it.
    var workspace = WorkspaceLayout.stacked
    @Binding var layout: PrintLayout?
    @Binding var edge: FilmEdgeLayout?
    @Binding var edgeSelection: FilmEdgeSelection?
    var cleanDistress: Binding<FilmEdgeDistress?> = .constant(nil)
    var renderedEdge: FilmEdgeLayout? = nil
    var resolvedType: FilmEdgeType = .negativePrint
    var adjustCrop: () -> Void = {}
    var printSourceSize: CGSize? = nil
    var imageReady = true
    var imageSubRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var canvasFill: Color? = nil
    var canvasFillRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onEdgeEditingChanged: (Bool) -> Void = { _ in }
    var onDiscreteLayoutChange: ((PrintLayout?) -> Void)? = nil
    var onDiscreteEdgeChange: ((FilmEdgeLayout?) -> Void)? = nil
    var onDiscreteCleanDistressChange: ((FilmEdgeDistress?) -> Void)? = nil
    var onSwitchPresentation: ((Bool) -> Void)? = nil
    var onDistressEdited: ((FilmEdgeDistress?) -> Void)? = nil
    /// Full-resolution pixels for the loupe, when the workspace has rendered them.
    var loupeImage: UIImage? = nil
    var loupeRefining = false
    var loupeWidth: CGFloat? = nil
    var loupePatch: PhotoRenderer.Detail? = nil
    var onLoupeInspect: ((CGRect) -> Void)? = nil
    @Binding var showLoupe: Bool
    var loupeAnchor: Binding<CGPoint?>? = nil
    @State private var fallbackLoupeAnchor: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("darkroom.light.on") private var tableLit = true
    @State private var expanded = false
    @State private var tab: Tab = .cleanPrint
    private enum Tab: String { case cleanPrint, filmEdge, distress }
    private var resolvedLoupeAnchor: Binding<CGPoint?> { loupeAnchor ?? $fallbackLoupeAnchor }
    /// A film-edge enlarger print starts on 5 × 7; anything else starts as the photo itself.
    private var current: PrintLayout {
        if let layout { return layout }
        if case .enlarger = content { return .enlargerDefault }
        return PrintLayout()
    }
    private var sourceSize: CGSize { printSourceSize ?? image.size }
    private var isEnlargerPrint: Bool {
        guard edge != nil, let activeEdge = renderedEdge ?? edge else { return false }
        return activeEdge.distress.enlargerPrint || (renderedEdge == nil && resolvedType == .negativePrint)
    }
    /// What is on the sheet: the picture, or a film-edge canvas with or without its own easel.
    private var content: PrintGeometry.Content {
        guard edge != nil, let activeEdge = renderedEdge ?? edge else { return .picture }
        return isEnlargerPrint ? .enlarger(frame: activeEdge.easelFrame(canvas: sourceSize)) : .scan
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if workspace == .sideBySide {
                    HStack(spacing: 12) {
                        preview
                        inspector(height: nil).frame(width: WorkspaceLayout.panelWidth(in: proxy.size.width))
                    }
                    .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                } else {
                    let collapsedHeight = min(202, max(160, proxy.size.height * 0.42))
                    let expandedHeight = min(400, max(collapsedHeight, proxy.size.height - 156))
                    let collapsedReserve = 36 + 8 + collapsedHeight + 14
                    ZStack(alignment: .bottom) {
                        preview
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, collapsedReserve)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded = false }
                            }
                            .allowsHitTesting(expanded)
                            .accessibilityHidden(true)
                        inspector(height: expanded ? expandedHeight : collapsedHeight)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { LightTableBackdrop(lit: tableLit) }
        }
        .onAppear { tab = edge != nil ? .filmEdge : .cleanPrint }
        .onChange(of: edge != nil) { oldHasEdge, hasEdge in
            if oldHasEdge && !hasEdge && cleanDistress.wrappedValue == nil {
                tab = .cleanPrint
            } else if tab != .distress {
                tab = hasEdge ? .filmEdge : .cleanPrint
            }
        }
        .onDisappear { onEditingChanged(false) }
    }

    private var preview: some View {
        PrintPreview(image: imageReady ? image : nil, imageSize: sourceSize, layout: current, content: content,
                     imageSubRect: imageSubRect, canvasFill: canvasFill, canvasFillRect: canvasFillRect,
                     paperColor: (isEnlargerPrint && imageReady && canvasFill == nil) ? PaperTone.color(of: image) : .white,
                     loupeImage: loupeImage, loupeRefining: loupeRefining, loupeWidth: loupeWidth,
                     loupePatch: loupePatch, onLoupeInspect: onLoupeInspect,
                     showLoupe: showLoupe, tableLit: tableLit, loupeAnchor: resolvedLoupeAnchor)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) { LightTableSwitch(lit: $tableLit) }
            .overlay(alignment: .topLeading) {
                Button(showLoupe ? String(localized: "darkroom.hide_loupe", defaultValue: "Hide loupe")
                                 : String(localized: "darkroom.show_loupe", defaultValue: "Show loupe"),
                       systemImage: "magnifyingglass") {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                        showLoupe.toggle()
                    }
                }
                .photoActionStyle(selected: showLoupe)
                .accessibilityAddTraits(showLoupe ? .isSelected : [])
                .accessibilityIdentifier("darkroom.loupe.toggle")
            }
    }

    /// `height` is nil when the controls fill their column and have nothing to expand into.
    private func inspector(height: CGFloat?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                PanelTabs(
                    options: [
                        (Tab.cleanPrint, String(localized: "darkroom.clean_print", defaultValue: "Clean print")),
                        (.filmEdge, String(localized: "darkroom.film_edge", defaultValue: "Film edge")),
                        (.distress, String(localized: "darkroom.distress", defaultValue: "Distress")),
                    ],
                    selection: Binding(
                        get: { tab },
                        set: { next in
                            tab = next
                            switch next {
                            case .cleanPrint:
                                if edge != nil {
                                    if let onSwitchPresentation { onSwitchPresentation(false) } else { edge = nil }
                                }
                            case .filmEdge:
                                if edge == nil {
                                    if let onSwitchPresentation { onSwitchPresentation(true) } else { edge = FilmEdgeLayout.newDefault() }
                                }
                            case .distress:
                                break
                            }
                        }),
                    prefix: "darkroom.")
                if height != nil { PanelExpansionButton(expanded: $expanded, identifier: "darkroom.expand") }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .cleanPrint:
                        paperControls
                        if showsEasel { easelControls }
                    case .filmEdge:
                        edgeControls
                        paperControls
                        if showsEasel { easelControls }
                    case .distress:
                        distressControls
                    }
                }
                .font(.footnote).padding(16)
            }
            .accessibilityIdentifier("darkroom.controls")
            .frame(maxWidth: .infinity, maxHeight: height == nil ? .infinity : nil, alignment: .top)
            .frame(height: height, alignment: .top)
            .clipped()
            .adaptiveGlassRect(cornerRadius: 24)
        }
    }

    private enum FormatChoice: String { case film35, roll120 }
    /// Auto, or one of the film-edge types (by raw value).
    private struct EdgeChoice: RawRepresentable, Hashable {
        let rawValue: String
        static let auto = EdgeChoice(rawValue: "auto")
    }
    private var fallbackEdge: FilmEdgeLayout { FilmEdgeLayout.previewFallback }
    private var formatChoice: FormatChoice {
        guard let edge else { return .film35 }
        return edge.format == .roll120 ? .roll120 : .film35
    }
    /// Change the film edge, starting from the default when there is none yet.
    private func setEdge(_ change: (inout FilmEdgeLayout) -> Void) {
        var next = edge ?? FilmEdgeLayout.newDefault()
        change(&next)
        edge = next
    }
    private func setDiscreteEdge(_ change: (inout FilmEdgeLayout) -> Void) {
        var next = edge ?? FilmEdgeLayout.newDefault()
        change(&next)
        if let onDiscreteEdgeChange { onDiscreteEdgeChange(next) } else { edge = next }
    }
    private func edgeBinding<Value>(_ path: WritableKeyPath<FilmEdgeLayout, Value>) -> Binding<Value> {
        Binding(get: { (edge ?? fallbackEdge)[keyPath: path] }, set: { value in setEdge { $0[keyPath: path] = value } })
    }
    /// A zoom stored as a fraction and shown as a percentage, kept inside its range.
    private func percentBinding(_ path: WritableKeyPath<FilmEdgeLayout, Double>, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { (edge ?? fallbackEdge)[keyPath: path] * 100 }, set: { value in
            setEdge { $0[keyPath: path] = min(max(value / 100, range.lowerBound), range.upperBound) }
        })
    }
    private var edgeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row: Auto follows Develop; a type pins the edge. Auto keeps the last pinned type.
            PanelTabs(
                options: [(EdgeChoice.auto, String(localized: "common.auto", defaultValue: "Auto"))]
                    + FilmEdgeType.allCases.map { (EdgeChoice(rawValue: $0.rawValue), $0.title) },
                selection: Binding(get: {
                    let current = edgeSelection ?? FilmEdgeSelection()
                    return current.mode == .automatic ? .auto : EdgeChoice(rawValue: current.manualType.rawValue)
                }, set: { choice in
                    var next = edgeSelection ?? FilmEdgeSelection()
                    if let type = FilmEdgeType(rawValue: choice.rawValue) {
                        next.mode = .manual
                        next.manualType = type
                    } else {
                        next.mode = .automatic
                    }
                    edgeSelection = next
                }),
                prefix: "darkroom.edge.type.",
                surface: .inPanel)
            if (edgeSelection ?? FilmEdgeSelection()).mode == .automatic {
                LabeledContent(String(localized: "darkroom.edge.from_develop", defaultValue: "From Develop"), value: resolvedType.title)
                    .font(.caption).accessibilityIdentifier("darkroom.edge.resolved")
            }
            PanelTabs(
                options: [(FormatChoice.film35, "35 mm"), (.roll120, "120")],
                selection: Binding(get: { formatChoice }, set: { choice in
                    setEdge { $0.setFormat(choice == .roll120 ? .roll120 : .film35) }
                }),
                prefix: "darkroom.edge.format.",
                surface: .inPanel)
            if (edge ?? fallbackEdge).format == .film35 {
                PanelTabs(
                    options: FilmEdgeLayout.Frame35.allCases.map { ($0, $0.title) },
                    selection: Binding(
                        get: { (edge ?? fallbackEdge).frame35 },
                        set: { frame in setEdge { $0.setFrame35(frame) } }),
                    prefix: "darkroom.edge.frame35.",
                    surface: .inPanel)
                PanelTabs(
                    options: [
                        (.auto, String(localized: "common.auto", defaultValue: "Auto")),
                        (.stillKS, String(localized: "darkroom.perforations.still", defaultValue: "35 mm still (KS)")),
                        (.cineBH, String(localized: "darkroom.perforations.cine", defaultValue: "35 mm cine (BH)")),
                    ],
                    selection: edgeBinding(\.sourcePerforations),
                    prefix: "darkroom.edge.perforations.",
                    surface: .inPanel)
            }
            if edge?.format == .roll120 {
                PanelTabs(
                    options: FilmEdgeLayout.RollFrame.allCases.map { ($0, $0.title) },
                    selection: edgeBinding(\.rollFrame),
                    prefix: "darkroom.edge.frame.",
                    surface: .inPanel)
                PanelTabs(
                    options: FilmEdgeLayout.RollGate.allCases.map { ($0, $0.title) },
                    selection: edgeBinding(\.rollGate),
                    prefix: "darkroom.edge.body.",
                    surface: .inPanel)
            }
            ViewThatFits(in: .horizontal) {
                HStack { gateSize; Spacer(); cropButton }
                VStack(alignment: .leading, spacing: 6) { gateSize; cropButton }
            }
            Divider().padding(.vertical, 4)
            gateControls
            if resolvedType == .negativePrint { zoomControl } else { scanZoomControl }
            Divider().padding(.vertical, 4)
            handlingControls
            Divider().padding(.vertical, 4)
        }
    }

    // MARK: Gate — the camera and holder. Fixed per setup, remembered for the next edit.
    private var gate: FilmEdgeGate { edge?.gate ?? FilmEdgeGate() }
    private var gateControls: some View {
        let activeEdge = edge ?? fallbackEdge
        let defaultGateScale = (activeEdge.format == .film35 && activeEdge.frame35 == .full) ? 101.5 : 100.0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.gate", defaultValue: "Gate")).foregroundStyle(.secondary)
                if gate.kind == nil {
                    Text(String(localized: "darkroom.distress.custom", defaultValue: "Custom"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            PanelTabs(
                options: FilmEdgeGate.Kind.allCases.map { ($0, $0.title) },
                selection: Binding(get: { gate.kind ?? .natural }, set: { kind in setEdge { $0.gate = FilmEdgeGate(kind) } }),
                prefix: "darkroom.gate.", isSelectionActive: gate.kind != nil, surface: .inPanel)
            NumericControl(
                title: String(localized: "darkroom.gate.size", defaultValue: "Gate size"),
                value: percentBinding(\.apertureScale, in: FilmEdgeLayout.apertureScaleRange),
                range: 96...104, step: 0.1, minimum: 96, maximum: 104, unit: "%",
                identifier: "darkroom.gate.size", defaultValue: defaultGateScale, fillOrigin: 100,
                onEditingChanged: onEdgeEditingChanged)
        }
    }

    // MARK: Handling — how the negative sits in the gate and carrier.
    private var handlingControls: some View {
        let d = (edge ?? fallbackEdge).distress
        let tiltChanged = abs(d.tilt * d.amount - d.effective.tilt) > 1e-6
        let bulgeChanged = abs(d.bulge * d.amount - d.effective.bulge) > 1e-6
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.distress.handling", defaultValue: "Handling"))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    String(localized: "darkroom.handling.new_seed", defaultValue: "New handling"),
                    systemImage: "dice"
                ) {
                    setDiscreteEdge { $0.distress.rerollHandling(seed: UInt32.random(in: 1...UInt32.max)) }
                }
                .panelIconButton().accessibilityIdentifier("darkroom.handling.seed")
            }
            distressSlider(
                String(localized: "darkroom.distress.extra_tilt", defaultValue: "Crooked loading"), \.tilt,
                step: 0.05, unit: "°", identifier: "tilt", fillOrigin: 0)
            if abs(d.amount - 1) > 0.005 {
                let eff = abs(d.effective.tilt) < 1e-6 ? 0.0 : d.effective.tilt
                let effectiveTilt = eff.formatted(
                    .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false))
                ) + "°"
                let clamped = tiltChanged || abs(d.tilt * d.amount) > 3 + 1e-6
                Text(
                    clamped
                        ? String(localized: "darkroom.distress.effective_clamped", defaultValue: "Rendered: \(effectiveTilt) (clamped)")
                        : String(localized: "darkroom.distress.effective", defaultValue: "Effective: \(effectiveTilt)"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("darkroom.distress.tilt.effective")
            }
            distressSlider(
                String(localized: "darkroom.distress.curl", defaultValue: "Film curl"), \.bulge,
                scale: 100, step: 1, unit: "%", identifier: "bulge", fillOrigin: 0)
            if abs(d.amount - 1) > 0.005 {
                let pct = abs(d.effective.bulge) < 1e-6 ? 0.0 : d.effective.bulge * 100
                let effectiveBulge = pct.formatted(
                    .number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false))
                ) + "%"
                let clamped = bulgeChanged || abs(d.bulge * d.amount) > 1.5 + 1e-6
                Text(
                    clamped
                        ? String(localized: "darkroom.distress.effective_clamped", defaultValue: "Rendered: \(effectiveBulge) (clamped)")
                        : String(localized: "darkroom.distress.effective", defaultValue: "Effective: \(effectiveBulge)"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("darkroom.distress.bulge.effective")
            }
            if formatChoice == .film35 {
                distressSlider(
                    String(localized: "darkroom.distress.hole_variation", defaultValue: "Sprocket variation"),
                    \.holeVariation, scale: 100, step: 1, unit: "%", identifier: "holeVariation")
            }
        }
    }

    // MARK: Distress — surface fog, light leaks, dust and scratches on both Clean print and Film edge.
    private var distress: FilmEdgeDistress {
        edge?.distress ?? cleanDistress.wrappedValue ?? .cleanPrintFallback
    }
    private func setDistress(_ change: (inout FilmEdgeDistress) -> Void) {
        if edge != nil {
            var updatedDistress: FilmEdgeDistress?
            setEdge {
                change(&$0.distress)
                updatedDistress = $0.distress
            }
            onDistressEdited?(updatedDistress)
        } else {
            var next = cleanDistress.wrappedValue ?? .cleanPrintFallback
            change(&next)
            let normalized: FilmEdgeDistress? = (next.cleanPrintPreset == .clean && !next.scratchesInImage) ? nil : next
            cleanDistress.wrappedValue = normalized
            onDistressEdited?(normalized)
        }
    }
    private func setDiscreteDistress(_ change: (inout FilmEdgeDistress) -> Void) {
        if edge != nil {
            var updatedDistress: FilmEdgeDistress?
            setDiscreteEdge {
                change(&$0.distress)
                updatedDistress = $0.distress
            }
            onDistressEdited?(updatedDistress)
        } else {
            var next = cleanDistress.wrappedValue ?? .cleanPrintFallback
            change(&next)
            let normalized: FilmEdgeDistress? = (next.cleanPrintPreset == .clean && !next.scratchesInImage) ? nil : next
            if let onDiscreteCleanDistressChange {
                onDiscreteCleanDistressChange(normalized)
            } else {
                cleanDistress.wrappedValue = normalized
            }
            onDistressEdited?(normalized)
        }
    }
    private func distressBinding(_ path: WritableKeyPath<FilmEdgeDistress, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { distress[keyPath: path] * scale }, set: { value in
            let range = FilmEdgeDistress.ranges[path] ?? (0...1)
            setDistress { $0[keyPath: path] = min(max(value / scale, range.lowerBound), range.upperBound) }
        })
    }
    private var distressControls: some View {
        let burnActive = distress.isLeakEnabled && distress.leakShape == .burn
        let activePreset = edge != nil ? distress.preset : distress.cleanPrintPreset
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "darkroom.distress", defaultValue: "Distress")).foregroundStyle(.secondary)
                if activePreset == nil {
                    Text(String(localized: "darkroom.distress.custom", defaultValue: "Custom"))
                        .font(.caption).foregroundStyle(.tertiary).accessibilityIdentifier("darkroom.distress.customLabel")
                }
                Spacer()
                Button(String(localized: "darkroom.distress.new_seed", defaultValue: "New pattern"), systemImage: "dice") {
                    setDiscreteDistress { $0.rerollPattern(seed: UInt32.random(in: 1...UInt32.max)) }
                }
                .panelIconButton().accessibilityIdentifier("darkroom.distress.seed")
            }
            PanelTabs(
                options: FilmEdgeDistress.Preset.allCases.map { ($0, $0.title) },
                selection: Binding(
                    get: { activePreset ?? .lab },
                    set: { preset in
                        let hasEdge = edge != nil
                        setDiscreteDistress {
                            if hasEdge { $0.apply(preset) } else { $0.applyCleanPrintPreset(preset) }
                        }
                    }),
                prefix: "darkroom.distress.", isSelectionActive: activePreset != nil, surface: .inPanel)
            distressSlider(String(localized: "darkroom.distress.amount", defaultValue: "Amount"), \.amount,
                           scale: 100, step: 1, unit: "%", identifier: "amount")
            Divider().padding(.vertical, 2)
            distressGroup(String(localized: "darkroom.distress.light", defaultValue: "Fog and leaks")) {
                HStack(spacing: 6) {
                    PanelTabs(
                        options: FilmEdgeDistress.LeakShape.allCases.map { ($0, $0.title) },
                        selection: Binding(
                            get: { distress.leakShape },
                            set: { shape in setDiscreteDistress { $0.toggleLeakShape(shape) } }
                        ),
                        prefix: "darkroom.distress.shape.",
                        isSelectionActive: distress.isLeakEnabled,
                        surface: .inPanel,
                        onReselect: { shape in setDiscreteDistress { $0.toggleLeakShape(shape) } }
                    )
                    Button(
                        String(
                            localized: "darkroom.distress.reroll_leak",
                            defaultValue: "Randomize leak"),
                        systemImage: "dice"
                    ) {
                        setDiscreteDistress { $0.rerollLeak() }
                    }
                    .panelIconButton()
                    .accessibilityIdentifier("darkroom.distress.leakSeed")
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "darkroom.distress.leak_shape", defaultValue: "Leak shape"))
                .accessibilityIdentifier("darkroom.distress.leakShape")
                Picker(String(localized: "darkroom.distress.leak_kind", defaultValue: "Leak path"), selection: Binding(
                    get: { distress.leakKind }, set: { kind in setDistress {
                        if $0.leakKind != kind { $0.warmth = FilmEdgeDistress.defaultWarmth(kind) }
                        $0.leakKind = kind
                    } })) {
                    Text(String(localized: "darkroom.distress.leak_back", defaultValue: "Back (door, seal)")).tag(FilmEdgeDistress.LeakKind.back)
                    Text(String(localized: "darkroom.distress.leak_front", defaultValue: "Front (through lens)")).tag(FilmEdgeDistress.LeakKind.front)
                }.pickerStyle(.segmented).disabled(burnActive).accessibilityIdentifier("darkroom.distress.leakKind")
                distressSlider(String(localized: "darkroom.distress.leak_strength", defaultValue: "Leak"), \.leak,
                               scale: 100, step: 1, unit: "%", identifier: "leak")
                if abs(distress.amount - 1) > 0.005 && distress.isLeakEnabled {
                    let effectiveLeak = (distress.effective.leak * 100).formatted(.number.precision(.fractionLength(0))) + "%"
                    Text(String(localized: "darkroom.distress.effective", defaultValue: "Effective: \(effectiveLeak)"))
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("darkroom.distress.leak.effective")
                }
                if burnActive {
                    distressSlider(
                        String(localized: "darkroom.distress.burn_coverage", defaultValue: "Coverage"),
                        \.burnCoverage, scale: 100, step: 1, unit: "%", identifier: "burnCoverage")
                    distressSlider(
                        String(localized: "darkroom.distress.burn_texture", defaultValue: "Burn texture"),
                        \.burnTexture, scale: 100, step: 1, unit: "%", identifier: "burnTexture")
                } else {
                    distressSlider(String(localized: "darkroom.distress.leak_size", defaultValue: "Leak size"), \.leakSize,
                                   step: 0.5, unit: "mm", identifier: "leakSize")
                }
                distressSlider(String(localized: "darkroom.distress.leak_position", defaultValue: "Leak position"), \.leakPosition,
                               scale: 100, step: 1, unit: "%", identifier: "leakPosition")
                distressSlider(String(localized: "darkroom.distress.edge_fog", defaultValue: "Edge fog"), \.edgeFog,
                               scale: 100, step: 1, unit: "%", identifier: "fog")
            }
            Divider().padding(.vertical, 2)
            distressGroup(String(localized: "darkroom.distress.damage", defaultValue: "Dust and scratches")) {
                distressSlider(String(localized: "darkroom.distress.dust", defaultValue: "Dust"), \.dust,
                               scale: 100, step: 1, unit: "%", identifier: "dust")
                HStack(alignment: .bottom, spacing: 10) {
                    distressSlider(String(localized: "darkroom.distress.scratches", defaultValue: "Scratches"), \.scratches,
                                   scale: 100, step: 1, unit: "%", identifier: "scratches")
                    Button(String(localized: "darkroom.distress.scratches_in_image", defaultValue: "In photo")) {
                        setDiscreteDistress {
                            $0.scratchesInImage.toggle()
                            if $0.scratchesInImage && $0.scratches <= 1e-6 {
                                $0.scratches = 0.10
                            }
                        }
                    }
                    .capsuleActionButton(selected: distress.scratchesInImage)
                    .accessibilityValue(
                        distress.scratchesInImage
                            ? String(localized: "common.on", defaultValue: "On")
                            : String(localized: "common.off", defaultValue: "Off"))
                    .accessibilityIdentifier("darkroom.distress.scratchesInImage")
                }
            }
        }
    }
    private func distressGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
    private func distressSlider(_ title: String, _ path: WritableKeyPath<FilmEdgeDistress, Double>, scale: Double = 1,
                                step: Double, unit: String, identifier: String, fillOrigin: Double? = nil) -> some View {
        let range = FilmEdgeDistress.ranges[path] ?? (0...1)
        let scaled = (range.lowerBound * scale)...(range.upperBound * scale)
        let baselinePreset: FilmEdgeDistress.Preset = {
            if edge == nil {
                if let active = distress.cleanPrintPreset { return active }
                for candidate in FilmEdgeDistress.Preset.allCases {
                    var probe = distress
                    probe[keyPath: path] = candidate.values(seed: distress.seed)[keyPath: path]
                    if probe.cleanPrintPreset == candidate { return candidate }
                }
                return .clean
            }
            if let active = distress.preset { return active }
            for candidate in FilmEdgeDistress.Preset.allCases {
                var probe = distress
                probe[keyPath: path] = candidate.values(seed: distress.seed)[keyPath: path]
                if probe.preset == candidate { return candidate }
            }
            return .lab
        }()
        let presetDefault = path == \.amount
            ? 1.0
            : baselinePreset.values(seed: distress.seed)[keyPath: path]
        return NumericControl(
            title: title, value: distressBinding(path, scale: scale), range: scaled, step: step,
            minimum: scaled.lowerBound, maximum: scaled.upperBound, unit: unit,
            identifier: "darkroom.distress." + identifier,
            defaultValue: presetDefault * scale,
            fillOrigin: fillOrigin ?? scaled.lowerBound, onEditingChanged: onEdgeEditingChanged)
    }
    // MARK: Enlarger — the head's height sets how much of the frame the easel opening shows.
    private var zoomControl: some View {
        let border = (edge ?? fallbackEdge).easelBorder
        func mm(_ v: Double) -> String { abs(v).formatted(.number.precision(.fractionLength(2))) }
        let readout = abs(border.ends) < 0.005
            ? String(localized: "darkroom.easel.on_edge", defaultValue: "On the frame edge")
            : border.ends > 0
                ? String(localized: "darkroom.easel.rebate", defaultValue: "Rebate \(mm(border.ends)) × \(mm(border.sides)) mm")
                : String(localized: "darkroom.easel.cropped", defaultValue: "Crop \(mm(border.ends)) × \(mm(border.sides)) mm")
        return VStack(alignment: .leading, spacing: 3) {
            NumericControl(
                title: String(localized: "darkroom.easel.zoom", defaultValue: "Enlarger zoom"),
                value: percentBinding(\.printZoom, in: FilmEdgeLayout.printZoomRange),
                range: 90...110, step: 0.5, minimum: 90, maximum: 110, unit: "%",
                identifier: "darkroom.easel.zoom", defaultValue: 93, fillOrigin: 100,
                onEditingChanged: onEdgeEditingChanged)
            Text(readout).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("darkroom.easel.readout")
        }
    }
    /// The scan's counterpart to the enlarger zoom: how far past the frame the scanner's crop reaches.
    private var scanZoomControl: some View {
        NumericControl(
            title: String(localized: "darkroom.edge.scan_zoom", defaultValue: "Scan framing"),
            value: percentBinding(\.scanZoom, in: FilmEdgeLayout.scanZoomRange),
            range: 75...105, step: 0.5, minimum: 75, maximum: 105, unit: "%",
            identifier: "darkroom.edge.scanZoom", defaultValue: 90, fillOrigin: 100,
            onEditingChanged: onEdgeEditingChanged)
    }
    // MARK: Easel — blades on the paper: their edge and how they were set.
    /// Blades show wherever there is a border (or a film-edge enlarger print, which has its own).
    private var showsEasel: Bool {
        if case .enlarger = content { return true }
        return content == .picture && current.resolvedMargin(content) > 0
    }
    private var easelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "darkroom.easel", defaultValue: "Easel")).foregroundStyle(.secondary)
                Spacer()
                Toggle(String(localized: "darkroom.easel.hand_set", defaultValue: "Hand-set"), isOn: binding(\.handSet))
                    .fixedSize().accessibilityIdentifier("darkroom.easel.handSet")
                Button(String(localized: "darkroom.easel.new_placement", defaultValue: "New placement"), systemImage: "dice") {
                    var next = current
                    next.easelSeed = UInt32.random(in: 2...UInt32.max)
                    layout = next
                }
                .panelIconButton().accessibilityIdentifier("darkroom.easel.seed")
            }
            PanelTabs(
                options: Easel.Kind.allCases.map { ($0, $0.title) },
                selection: binding(\.blade),
                prefix: "darkroom.easel.blade.",
                surface: .inPanel)
        }
    }
    private var gateSize: some View {
        Text((edge ?? fallbackEdge).gateTitle(portrait: sourceSize.height > sourceSize.width))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("darkroom.edge.gate")
    }
    private var cropButton: some View {
        Button(String(localized: "darkroom.edge.adjust_crop", defaultValue: "Adjust crop"), systemImage: "crop", action: adjustCrop)
            .capsuleActionButton()
            .accessibilityIdentifier("darkroom.edge.adjustCrop")
    }

    // MARK: Paper — the sheet and the easel's white border.
    private var paperControls: some View {
        // Percent of the sheet's long side; below zero the picture runs past the sheet's edge.
        let fill = PrintGeometry.fillMargin(imageSize: sourceSize, layout: current, content: content)
        let margin = current.fill ? fill : current.resolvedMargin(content)
        let filled = current.fill
        let activeBorder = PrintLayout.Border.activePreset(margin: margin, fill: filled)
        func setMargin(_ value: Double) {
            var next = current
            next.fill = false
            next.margin = min(max(value, PrintLayout.marginRange.lowerBound), PrintLayout.marginRange.upperBound)
            layout = next
        }
        func setFullBleed() {
            var next = current
            next.fill = true
            next.margin = nil
            let value = next.isDefault ? nil : next
            if let onDiscreteLayoutChange { onDiscreteLayoutChange(value) } else { layout = value }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker(String(localized: "darkroom.paper", defaultValue: "Paper"), selection: binding(\.paper)) {
                    ForEach(PrintLayout.Paper.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).accessibilityIdentifier("darkroom.paper")
                if current.paper != .asImage {
                    Button(String(localized: "darkroom.rotate_paper", defaultValue: "Rotate paper"), systemImage: "rotate.right") {
                        var next = current
                        let landscape = current.paperAspect(imageAspect: sourceSize.width / sourceSize.height) > 1
                        next.orientation = landscape ? .portrait : .landscape
                        layout = next
                    }
                    .panelIconButton().accessibilityIdentifier("darkroom.rotatePaper")
                }
            }
            // Presets for the usual widths; No border sets true short-side full bleed.
            PanelTabs(
                options: PrintLayout.Border.allCases.map { ($0, $0.title) },
                selection: Binding(
                    get: { activeBorder ?? .none },
                    set: { border in
                        if border == .none { setFullBleed() } else { setMargin(border.margin) }
                    }),
                prefix: "darkroom.border.", isSelectionActive: activeBorder != nil, surface: .inPanel)
            HStack(alignment: .bottom, spacing: 10) {
                NumericControl(
                    title: String(localized: "darkroom.border", defaultValue: "Border"),
                    value: Binding(get: { margin * 100 }, set: { setMargin($0 / 100) }),
                    range: (PrintLayout.marginRange.lowerBound * 100)...(PrintLayout.marginRange.upperBound * 100), step: 0.5,
                    minimum: PrintLayout.marginRange.lowerBound * 100, maximum: PrintLayout.marginRange.upperBound * 100, unit: "%",
                    identifier: "darkroom.border",
                    defaultValue: { var d = current; d.margin = nil; d.fill = false; return d.resolvedMargin(content) * 100 }(),
                    fillOrigin: 0, onEditingChanged: onEditingChanged)
                Button(String(localized: "darkroom.fill", defaultValue: "Fill"), action: setFullBleed)
                    .capsuleActionButton(selected: filled)
                    .accessibilityValue(filled ? String(localized: "common.on", defaultValue: "On") : String(localized: "common.off", defaultValue: "Off"))
                    .accessibilityIdentifier("darkroom.fill")
            }
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PrintLayout, Value>) -> Binding<Value> {
        Binding(get: { current[keyPath: keyPath] }, set: { value in
            var next = current
            next[keyPath: keyPath] = value
            layout = next.isDefault ? nil : next
        })
    }
}

private struct PrintPreview: View {
    let image: UIImage?
    let imageSize: CGSize
    let layout: PrintLayout
    var content = PrintGeometry.Content.picture
    var imageSubRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var canvasFill: Color? = nil
    var canvasFillRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The sheet continues the print's own unexposed margin.
    var paperColor = Color.white
    var loupeImage: UIImage? = nil
    var loupeRefining = false
    /// Pixel width the loupe's full-resolution frame will have, known before it is rendered.
    var loupeWidth: CGFloat? = nil
    var loupePatch: PhotoRenderer.Detail? = nil
    var onLoupeInspect: ((CGRect) -> Void)? = nil
    var showLoupe = false
    var tableLit = true
    @Binding var loupeAnchor: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let unitSquare = CGRect(x: 0, y: 0, width: 1, height: 1)
    var body: some View {
        GeometryReader { viewport in
            ZStack {
                if let geometry = PrintGeometry(imageSize: imageSize, layout: layout, longEdge: 1000, content: content) {
                    let blades = bladeMask(geometry)
                    let fit = min(max(1, viewport.size.width - 44) / geometry.paperSize.width,
                                  max(1, viewport.size.height - 36) / geometry.paperSize.height)
                    let paper = CGSize(width: geometry.paperSize.width * fit, height: geometry.paperSize.height * fit)
                    let paperFrame = CGRect(x: (viewport.size.width - paper.width) / 2,
                                            y: (viewport.size.height - paper.height) / 2,
                                            width: paper.width, height: paper.height)
                    let loupeCenter = DarkroomLoupe.resolvedCenter(
                        anchor: loupeAnchor, paperFrame: paperFrame, bounds: viewport.size
                    )
                    PrintSheet(image: image, size: paper,
                               imageRect: CGRect(x: geometry.imageRect.minX * fit, y: geometry.imageRect.minY * fit,
                                                 width: geometry.imageRect.width * fit, height: geometry.imageRect.height * fit),
                               imageSubRect: imageSubRect, canvasFill: canvasFill, canvasFillRect: canvasFillRect,
                               paper: paperColor, blades: blades)
                    .shadow(color: .black.opacity(0.18), radius: 7, x: 0, y: 4)
                    .position(x: viewport.size.width / 2, y: viewport.size.height / 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(String(localized: "darkroom.print_preview", defaultValue: "Print preview"))
                    .accessibilityValue(layout.paper.title + ", " + (geometry.paperSize.width > geometry.paperSize.height
                        ? String(localized: "crop.landscape", defaultValue: "Landscape")
                        : String(localized: "crop.portrait", defaultValue: "Portrait")))
                    .accessibilityIdentifier("darkroom.preview")
                    ZStack {
                        if showLoupe {
                            DarkroomLoupe(
                                image: loupeImage ?? image,
                                imageSubRect: loupeImage != nil ? Self.unitSquare : imageSubRect,
                                canvasFill: loupeImage != nil ? nil : canvasFill,
                                canvasFillRect: loupeImage != nil ? Self.unitSquare : canvasFillRect,
                                center: loupeCenter,
                                imageFrame: CGRect(x: paperFrame.minX + geometry.imageRect.minX * fit,
                                                   y: paperFrame.minY + geometry.imageRect.minY * fit,
                                                   width: geometry.imageRect.width * fit, height: geometry.imageRect.height * fit),
                                paperFrame: paperFrame, bounds: viewport.size,
                                refining: loupeRefining || image == nil || (loupeImage == nil && loupePatch == nil),
                                surround: LightTableBackdrop.surround(lit: tableLit), paper: paperColor,
                                fullWidth: loupeWidth, patch: loupePatch,
                                blades: blades,
                                onInspect: onLoupeInspect,
                                anchor: $loupeAnchor)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                        }
                    }
                    .frame(width: DarkroomLoupe.diameter, height: DarkroomLoupe.diameter)
                    .position(loupeCenter)
                    .allowsHitTesting(showLoupe)
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .coordinateSpace(name: DarkroomLoupe.viewportCoordinateSpace)
        }
    }
    /// The clean print's blade mask, at the loupe's resolution so its edge holds up at 100 %.
    private func bladeMask(_ geometry: PrintGeometry) -> CGImage? {
        guard geometry.magnification > 0 else { return nil }
        let long = min(4096, max(loupeWidth.map { $0 * max(1, imageSize.height / imageSize.width) } ?? 0,
                                 max(imageSize.width, imageSize.height), 1000))
        let k = long / max(imageSize.width, imageSize.height)
        return Easel.mask(width: Int((imageSize.width * k).rounded()), height: Int((imageSize.height * k).rounded()),
                          magnification: geometry.magnification, kind: layout.blade, seed: layout.easelSeed)
    }
}

#if DEBUG
private enum DarkroomFixture {
    static let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400)).image { context in
        UIColor(red: 0.4, green: 0.58, blue: 0.68, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        UIColor(red: 0.24, green: 0.37, blue: 0.31, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 220, width: 600, height: 180))
        UIColor(red: 0.86, green: 0.76, blue: 0.57, alpha: 1).setFill()
        context.fill(CGRect(x: 60, y: 180, width: 180, height: 150))
    }
}

#Preview("Clean print") {
    @Previewable @State var layout: PrintLayout? = nil
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil), showLoupe: .constant(true))
}

#Preview("Portrait paper · Larger text") {
    @Previewable @State var layout: PrintLayout? = {
        var value = PrintLayout()
        value.paper = .eightByTen
        value.orientation = .portrait
        value.margin = 0.08
        return value
    }()
    DarkroomView(image: DarkroomFixture.image, layout: $layout, edge: .constant(nil), edgeSelection: .constant(nil), showLoupe: .constant(true))
        .environment(\.dynamicTypeSize, .accessibility1)
}
#endif
