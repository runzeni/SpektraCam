import SwiftUI

/// Native Liquid Glass on iOS 26+, with native Material and bordered controls on iOS 17–18.
struct AdaptiveGlassContainer<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

struct AdaptiveToolbarSpacer: ToolbarContent {
    enum Kind { case fixed, flexible }
    let kind: Kind
    let placement: ToolbarItemPlacement

    init(_ kind: Kind = .flexible, placement: ToolbarItemPlacement = .automatic) {
        self.kind = kind
        self.placement = placement
    }

    var body: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            switch kind {
            case .fixed:
                ToolbarSpacer(.fixed, placement: placement)
            case .flexible:
                ToolbarSpacer(.flexible, placement: placement)
            }
        } else if kind == .flexible {
            ToolbarItem(placement: placement) { Spacer() }
        }
    }
}

struct AdaptiveToolbarItem<Content: View>: ToolbarContent {
    enum Background { case automatic, visible, hidden }
    let placement: ToolbarItemPlacement
    var background: Background = .automatic
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            switch background {
            case .automatic:
                ToolbarItem(placement: placement, content: content)
            case .visible:
                ToolbarItem(placement: placement, content: content)
                    .sharedBackgroundVisibility(.visible)
            case .hidden:
                ToolbarItem(placement: placement, content: content)
                    .sharedBackgroundVisibility(.hidden)
            }
        } else {
            ToolbarItem(placement: placement, content: content)
        }
    }
}

extension View {
    @ViewBuilder func adaptiveGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder func adaptiveGlassRect(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Floating inspector/popover card that may straddle bright chrome (`PhotoTheme.canvas`)
    /// and a dark photograph simultaneously, preventing a two-tone horizontal refraction seam.
    @ViewBuilder func adaptiveFloatingPanelSurface(
        cornerRadius: CGFloat, unifiedBackdrop: Bool
    ) -> some View {
        if unifiedBackdrop {
            if #available(iOS 26.0, macOS 26.0, *) {
                glassEffect(
                    .regular.tint(Color(uiColor: .secondarySystemBackground).opacity(0.84)),
                    in: .rect(cornerRadius: cornerRadius))
            } else {
                background(.thickMaterial, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            adaptiveGlassRect(cornerRadius: cornerRadius)
        }
    }

    @ViewBuilder func adaptiveGlassCapsule(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            background(.regularMaterial, in: .capsule)
        }
    }

    @ViewBuilder func adaptiveGlassCircle(interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
        } else {
            background(.regularMaterial, in: .circle)
        }
    }

    @ViewBuilder func adaptiveGlassDefault() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect()
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
    }

    @ViewBuilder func adaptiveGlassAccentSelection(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(
                .regular.tint(.accentColor).interactive(),
                in: .rect(cornerRadius: cornerRadius))
        } else {
            background(Color.accentColor, in: .rect(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder func adaptiveGlassID<ID: Hashable & Sendable>(
        _ id: ID, in namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder func adaptiveInitialTopScrollAnchor() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            defaultScrollAnchor(.top, for: .initialOffset)
        } else {
            defaultScrollAnchor(.top)
        }
    }

    /// Vibrancy-aware capsule button for actions inside Liquid Glass / Material surfaces.
    /// Avoids glass-on-glass nesting while adapting foreground and border legibility over
    /// both dark and light photo backdrops in every accent (including monochrome).
    func capsuleActionButton(selected: Bool = false) -> some View {
        buttonStyle(CapsuleActionButtonStyle(selected: selected))
    }
}

struct CapsuleActionButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .foregroundStyle(
                selected
                    ? AnyShapeStyle(.onAccent)
                    : (isEnabled
                        ? AnyShapeStyle(Color.primary)
                        : AnyShapeStyle(Color.secondary.opacity(0.55)))
            )
            .background {
                if selected {
                    Capsule().fill(Color.accentColor)
                } else if isEnabled {
                    Capsule()
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.09))
                        .overlay {
                            Capsule().strokeBorder(Color.primary.opacity(0.22), lineWidth: 0.75)
                        }
                } else {
                    Capsule()
                        .fill(Color.primary.opacity(0.03))
                        .overlay {
                            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                        }
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(.capsule)
    }
}

/// Shared circular dismiss control for modal sheets, preserving the localized "Done" label.
struct SheetDismissButton: View {
    let action: () -> Void
    var body: some View {
        Button(
            String(localized: "common.done", defaultValue: "Done"),
            systemImage: "xmark", action: action
        )
        .labelStyle(.iconOnly)
    }
}
