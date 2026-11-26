import SwiftUI

/// Editing modes; Export is a separate command. ED-02.
enum EditorTool: String, CaseIterable, Identifiable {
    case crop
    case develop
    case adjust
    case effects

    var id: Self { self }

    var title: String {
        switch self {
        case .crop: String(localized: "editor.crop", defaultValue: "Crop")
        case .develop: String(localized: "editor.develop", defaultValue: "Develop")
        case .adjust: String(localized: "editor.adjust", defaultValue: "Adjust")
        case .effects: String(localized: "editor.effects", defaultValue: "Effects")
        }
    }

    var symbolName: String {
        switch self {
        case .crop: "crop"
        case .develop: "camera.filters"
        case .adjust: "slider.horizontal.3"
        case .effects: "sparkles"
        }
    }

    static func primaryAction(darkroomActive: Bool) -> (title: String, symbol: String, id: String) {
        darkroomActive
            ? (String(localized: "common.export", defaultValue: "Export"), "square.and.arrow.up", "darkroom.export")
            : (String(localized: "darkroom.title", defaultValue: "Darkroom"), "lightbulb", "editor.export")
    }
}

/// System side-bar items for workspaces where the OS renders a vertical bar (e.g. iPhone Duo).
/// Stacked portrait workspaces use `EditorBottomBar` so narrow 375 pt screens never collapse
/// tools into an un-expandable `UIToolbar` overflow dot.
struct EditorToolbar: ToolbarContent {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    @Environment(\.appAccent) private var accent
    @ToolbarContentBuilder var body: some ToolbarContent {
        let action = EditorTool.primaryAction(darkroomActive: darkroomActive)
        ToolbarItemGroup(placement: .bottomBar) {
            ForEach(EditorTool.allCases) { tool in
                Button(tool.title, systemImage: tool.symbolName) {
                    activeTool = activeTool == tool ? nil : tool
                }
                .tint(activeTool == tool ? Color.accentColor : accent.idle)
                .accessibilityAddTraits(activeTool == tool ? .isSelected : [])
                .accessibilityIdentifier("editor.tool." + tool.rawValue)
            }
        }
        AdaptiveToolbarSpacer(.fixed, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button(action.title, systemImage: action.symbol, action: darkroomActive ? export : openDarkroom)
                .accessibilityIdentifier(action.id)
        }
    }
}

/// Bottom Liquid Glass tool bar for stacked portrait workspaces without a system vertical bar.
/// Follows compact Apple HIG tab-bar proportions (`50 pt` platter height, `12 pt` outer margins
/// aligned flush with the floating inspector above).
struct EditorBottomBar: View {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    @Namespace private var barNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            toolsPill
            actionPill
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity)
    }

    private var toolsPill: some View {
        Group {
            if typeSize.isAccessibilitySize {
                scrollingTools
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) {
                        ForEach(EditorTool.allCases) { tool in toolButton(tool, flexible: true) }
                    }
                    scrollingTools
                }
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity)
        .modifier(EditorPlatterGlassModifier(shape: Capsule()))
    }

    private var scrollingTools: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(EditorTool.allCases) { tool in
                        toolButton(tool, flexible: false).id(tool)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeTool) { _, tool in
                guard let tool else { return }
                if reduceMotion {
                    proxy.scrollTo(tool, anchor: .center)
                } else {
                    withAnimation(.snappy(duration: 0.22)) {
                        proxy.scrollTo(tool, anchor: .center)
                    }
                }
            }
        }
        .clipShape(.capsule)
    }

    private func toolButton(_ tool: EditorTool, flexible: Bool) -> some View {
        let selected = !darkroomActive && activeTool == tool
        return Button {
            activeTool = selected ? nil : tool
        } label: {
            EditorToolLabel(title: tool.title, symbol: tool.symbolName, selected: selected)
                .padding(.horizontal, flexible ? 4 : 10)
                .frame(
                    minWidth: 54,
                    maxWidth: flexible ? .infinity : nil,
                    minHeight: typeSize.isAccessibilitySize ? 54 : 44
                )
                .contentShape(.capsule)
                .fixedSize(horizontal: !flexible, vertical: false)
                .background {
                    if selected {
                        EditorSelectionPlatter(
                            shape: Capsule(), colorScheme: colorScheme, accent: accent
                        )
                        .matchedGeometryEffect(id: "editor.activeTool", in: barNamespace)
                    }
                }
        }
        .buttonStyle(EditorModeButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("editor.tool." + tool.rawValue)
        .accessibilityShowsLargeContentViewer { Label(tool.title, systemImage: tool.symbolName) }
    }

    private var actionPill: some View {
        let action = EditorTool.primaryAction(darkroomActive: darkroomActive)
        return Button {
            (darkroomActive ? export : openDarkroom)()
        } label: {
            EditorToolLabel(
                title: action.title, symbol: action.symbol, selected: false, isAction: true
            )
            .padding(.horizontal, 14)
            .frame(minWidth: 68, minHeight: typeSize.isAccessibilitySize ? 54 : 44)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(EditorModeButtonStyle())
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.id)
        .accessibilityShowsLargeContentViewer { Label(action.title, systemImage: action.symbol) }
        .padding(3)
        .modifier(EditorPlatterGlassModifier(shape: Capsule(), interactive: true))
        .adaptiveGlassID("editor.primaryAction", in: barNamespace)
    }
}

/// The same tools as the bottom bar, top to bottom on the trailing edge of a wide workspace.
struct EditorToolRail: View {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    @Namespace private var railNamespace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccent) private var accent

    var body: some View {
        let action = EditorTool.primaryAction(darkroomActive: darkroomActive)
        VStack(spacing: 10) {
            toolsGroup
            actionButton(action)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var toolsGroup: some View {
        ViewThatFits(in: .vertical) {
            toolStack
            ScrollView(.vertical) {
                toolStack
            }
            .scrollIndicators(.hidden)
            .clipShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .padding(4)
        .modifier(
            EditorPlatterGlassModifier(
                shape: RoundedRectangle(cornerRadius: 22, style: .continuous)))
    }

    private var toolStack: some View {
        VStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                let selected = !darkroomActive && activeTool == tool
                Button {
                    activeTool = selected ? nil : tool
                } label: {
                    EditorToolLabel(title: tool.title, symbol: tool.symbolName, selected: selected)
                        .padding(.horizontal, 8)
                        .frame(
                            minWidth: 58, maxWidth: .infinity,
                            minHeight: typeSize.isAccessibilitySize ? 54 : 44
                        )
                        .background {
                            if selected {
                                EditorSelectionPlatter(
                                    shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                                    colorScheme: colorScheme,
                                    accent: accent
                                )
                                .matchedGeometryEffect(id: "editor.activeTool", in: railNamespace)
                            }
                        }
                }
                .buttonStyle(EditorModeButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("editor.tool." + tool.rawValue)
                .accessibilityShowsLargeContentViewer { Label(tool.title, systemImage: tool.symbolName) }
            }
        }
    }

    private func actionButton(_ action: (title: String, symbol: String, id: String)) -> some View {
        Button {
            (darkroomActive ? export : openDarkroom)()
        } label: {
            EditorToolLabel(
                title: action.title, symbol: action.symbol, selected: false, isAction: true
            )
            .padding(.horizontal, 8)
            .frame(minWidth: 58, maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 54 : 44)
        }
        .buttonStyle(EditorModeButtonStyle())
        .accessibilityLabel(action.title)
        .accessibilityIdentifier(action.id)
        .accessibilityShowsLargeContentViewer { Label(action.title, systemImage: action.symbol) }
        .padding(4)
        .modifier(
            EditorPlatterGlassModifier(
                shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                interactive: true)
        )
        .adaptiveGlassID("editor.primaryAction", in: railNamespace)
    }
}

private struct EditorModeButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct EditorSelectionPlatter<S: InsettableShape>: View {
    let shape: S
    let colorScheme: ColorScheme
    let accent: AppAccent

    var body: some View {
        if colorScheme == .dark {
            shape.fill(Color.white.opacity(0.18))
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6)
                }
        } else {
            shape.fill(Color.white.opacity(0.92))
                .overlay {
                    shape.strokeBorder(Color.black.opacity(0.10), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
    }
}

private struct EditorPlatterGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
        }
    }
}

struct EditorToolLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    var isAction = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.appAccent) private var accent
    @ScaledMetric(relativeTo: .caption2) private var iconSize: CGFloat = 17

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: min(iconSize, 21), weight: selected ? .semibold : .medium))
                .frame(width: 22, height: 19)
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.caption2.weight(selected ? .semibold : .medium))
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(selected ? Color.accentColor : (isAction ? Color.primary : accent.idle))
    }
}
