import SwiftUI

/// Shared native pills for Develop, Adjust, Effects and Darkroom.
struct PanelTabs<Selection: Hashable & RawRepresentable>: View
where Selection.RawValue == String {
    enum Surface { case floating, inPanel }

    let options: [(Selection, String)]
    @Binding var selection: Selection
    let prefix: String
    var isSelectionActive = true
    var unavailable: Set<Selection> = []
    var surface: Surface = .floating
    var onReselect: ((Selection) -> Void)? = nil

    var body: some View {
        Group {
            if surface == .floating {
                scrollRow
                    .frame(height: 36)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            } else {
                scrollRow
                    .frame(minHeight: 34)
            }
        }
    }

    private var scrollRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { option in
                    let selected = isSelectionActive && selection == option.0
                    let disabled = unavailable.contains(option.0)
                    pillButton(option, selected: selected)
                        .accessibilityIdentifier(prefix + option.0.rawValue)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityShowsLargeContentViewer { Text(option.1) }
                        .disabled(disabled)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private func pillButton(_ option: (Selection, String), selected: Bool) -> some View {
        let base = Group {
            if surface == .floating {
                Button(option.1) { handleTap(option.0, selected: selected) }
                    .buttonStyle(FloatingTabPillStyle(selected: selected))
            } else {
                Button(option.1) { handleTap(option.0, selected: selected) }
                    .capsuleActionButton(selected: selected)
                    .frame(minHeight: 34)
                    .contentShape(.rect)
            }
        }
        if onReselect != nil {
            base.accessibilityValue(
                selected
                    ? String(localized: "common.on", defaultValue: "On")
                    : String(localized: "common.off", defaultValue: "Off")
            )
        } else {
            base
        }
    }

    private func handleTap(_ value: Selection, selected: Bool) {
        if selected, let onReselect {
            onReselect(value)
        } else {
            selection = value
        }
    }
}

private struct FloatingTabPillStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(selected ? .semibold : .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .foregroundStyle(
                selected
                    ? AnyShapeStyle(.onAccent)
                    : (isEnabled ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tertiary))
            )
            .modifier(FloatingTabPillSurface(selected: selected))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .frame(minWidth: 44)
            .frame(height: 36)
            .contentShape(Rectangle().inset(by: -4))
    }
}

private struct FloatingTabPillSurface: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if selected {
                content
                    .background(Color.accentColor, in: .capsule)
                    .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .capsule)
            } else {
                content
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            if selected {
                content.background(Color.accentColor, in: .capsule)
            } else {
                content
                    .background(.regularMaterial, in: .capsule)
                    .overlay {
                        Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    }
            }
        }
    }
}

struct PanelExpansionButton: View {
    @Binding var expanded: Bool
    let identifier: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 32, height: 32)
                .adaptiveGlassCircle(interactive: true)
                .frame(width: 40, height: 36)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            expanded
                ? String(localized: "editor.collapse_panel", defaultValue: "Collapse Panel")
                : String(localized: "editor.expand_panel", defaultValue: "Expand Panel")
        )
        .accessibilityIdentifier(identifier)
        .accessibilityValue(
            expanded
                ? String(localized: "common.expanded", defaultValue: "Expanded")
                : String(localized: "common.collapsed", defaultValue: "Collapsed"))
    }
}
