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
    private var actionTitle: String {
        darkroomActive
            ? String(localized: "common.export", defaultValue: "Export")
            : String(localized: "darkroom.title", defaultValue: "Darkroom")
    }
    private var actionSymbol: String { darkroomActive ? "square.and.arrow.up" : "lightbulb" }
    @ToolbarContentBuilder var body: some ToolbarContent {
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
            Button(actionTitle, systemImage: actionSymbol, action: darkroomActive ? export : openDarkroom)
                .accessibilityIdentifier(darkroomActive ? "darkroom.export" : "editor.export")
        }
    }
}

/// Bottom tool pills for stacked portrait workspaces without a system vertical bar.
/// Every tool keeps at least a 44 × 48 pt touch area across 320–440+ pt widths without UIToolbar overflow.
struct EditorBottomBar: View {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    private var actionTitle: String {
        darkroomActive
            ? String(localized: "common.export", defaultValue: "Export")
            : String(localized: "darkroom.title", defaultValue: "Darkroom")
    }
    private var actionSymbol: String { darkroomActive ? "square.and.arrow.up" : "lightbulb" }
    var body: some View {
        AdaptiveGlassContainer(spacing: 10) {
            HStack(spacing: 10) {
                toolsPill
                actionPill
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
    }

    private var toolsPill: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { tool in toolButton(tool) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .adaptiveGlassCapsule(interactive: true)
    }

    private func toolButton(_ tool: EditorTool) -> some View {
        let selected = activeTool == tool
        return Button {
            activeTool = selected ? nil : tool
        } label: {
            EditorToolLabel(title: tool.title, symbol: tool.symbolName, selected: selected)
                .frame(minWidth: 44, maxWidth: 58).frame(height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("editor.tool." + tool.rawValue)
        .accessibilityShowsLargeContentViewer { Label(tool.title, systemImage: tool.symbolName) }
    }

    private var actionPill: some View {
        HStack(spacing: 0) {
            Button(action: darkroomActive ? export : openDarkroom) {
                EditorToolLabel(title: actionTitle, symbol: actionSymbol, selected: false)
                    .frame(minWidth: 54).frame(height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(actionTitle)
            .accessibilityIdentifier(darkroomActive ? "darkroom.export" : "editor.export")
            .accessibilityShowsLargeContentViewer { Label(actionTitle, systemImage: actionSymbol) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .adaptiveGlassCapsule(interactive: true)
    }
}

/// The same tools as the bottom bar, top to bottom on the trailing edge of a wide workspace.
struct EditorToolRail: View {
    @Binding var activeTool: EditorTool?
    var darkroomActive = false
    let openDarkroom: () -> Void
    let export: () -> Void
    private var actionTitle: String {
        darkroomActive
            ? String(localized: "common.export", defaultValue: "Export")
            : String(localized: "darkroom.title", defaultValue: "Darkroom")
    }
    private var actionSymbol: String { darkroomActive ? "square.and.arrow.up" : "lightbulb" }
    var body: some View {
        AdaptiveGlassContainer(spacing: 12) {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    ForEach(EditorTool.allCases) { tool in
                        Button {
                            activeTool = activeTool == tool ? nil : tool
                        } label: {
                            EditorToolLabel(title: tool.title, symbol: tool.symbolName, selected: activeTool == tool)
                                .frame(width: 48, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(activeTool == tool ? .isSelected : [])
                        .accessibilityIdentifier("editor.tool." + tool.rawValue)
                        .accessibilityShowsLargeContentViewer { Label(tool.title, systemImage: tool.symbolName) }
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
                .adaptiveGlassRect(cornerRadius: 28, interactive: true)
                Button(action: darkroomActive ? export : openDarkroom) {
                    EditorToolLabel(title: actionTitle, symbol: actionSymbol, selected: false)
                        .frame(width: 48, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(actionTitle)
                .accessibilityIdentifier(darkroomActive ? "darkroom.export" : "editor.export")
                .accessibilityShowsLargeContentViewer { Label(actionTitle, systemImage: actionSymbol) }
                .padding(.vertical, 8).padding(.horizontal, 6)
                .adaptiveGlassRect(cornerRadius: 28, interactive: true)
            }
            .buttonStyle(.plain)
        }
    }
}

struct EditorToolLabel: View {
    let title: String
    let symbol: String
    let selected: Bool
    @Environment(\.appAccent) private var accent
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .frame(width: 24, height: 22)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .minimumScaleFactor(0.8).frame(height: 12)
        }
        .foregroundStyle(selected ? Color.accentColor : accent.idle)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }
}
