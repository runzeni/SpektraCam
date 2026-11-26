import SwiftUI

/// One standard circular action size (`44 × 44` visible circle and touch target, matching native
/// navigation bar items) shared across toolbars, floating photo actions, Compare, Loupe, and Crop.
private struct CircularActionSurface<Content: View>: View {
    var selected = false
    var prominent = false
    var destructive = false
    var isPressed = false
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled

    private var activeFill: Bool { isEnabled && (prominent || selected) }

    private var foreground: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Color.secondary.opacity(0.42)) }
        if activeFill { return AnyShapeStyle(.onAccent) }
        if destructive { return AnyShapeStyle(Color.red) }
        return AnyShapeStyle(Color.primary)
    }

    var body: some View {
        content()
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .font(.system(size: 17, weight: activeFill ? .semibold : .medium))
            .foregroundStyle(foreground)
            .frame(width: 44, height: 44)
            .modifier(CircularActionGlassModifier(activeFill: activeFill))
            .opacity(isPressed ? 0.82 : 1)
            .contentShape(.circle)
    }
}

private struct CircularActionGlassModifier: ViewModifier {
    let activeFill: Bool
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if activeFill {
                content
                    .background(Color.accentColor, in: .circle)
                    .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .circle)
            } else {
                content
                    .glassEffect(.regular.interactive(), in: .circle)
            }
        } else {
            content
                .background(
                    activeFill ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),
                    in: .circle
                )
                .overlay {
                    if !activeFill {
                        Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    }
                }
        }
    }
}

private struct PhotoActionButtonStyle: ButtonStyle {
    var selected = false
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        CircularActionSurface(
            selected: selected,
            prominent: prominent,
            destructive: configuration.role == .destructive,
            isPressed: configuration.isPressed
        ) {
            configuration.label
        }
    }
}

/// Matching `40 × 40` / `44 × 44` circular surface for `Menu` labels (History, Revert, Crop overflow).
struct PhotoActionMenuLabel: View {
    let title: String
    let systemImage: String
    var selected = false
    var prominent = false
    var isPressed = false

    var body: some View {
        CircularActionSurface(selected: selected, prominent: prominent, isPressed: isPressed) {
            Label(title, systemImage: systemImage)
        }
    }
}

extension View {
    func photoActionStyle(selected: Bool = false, prominent: Bool = false) -> some View {
        buttonStyle(PhotoActionButtonStyle(selected: selected, prominent: prominent))
    }
}

/// Reuse the root camera presentation from the library, photo and editor.
private struct CameraActionKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var openCamera: (() -> Void)? {
        get { self[CameraActionKey.self] }
        set { self[CameraActionKey.self] = newValue }
    }
}

struct CameraButton: View {
    var prominent = false
    @Environment(\.openCamera) private var openCamera
    var body: some View {
        Group {
            if prominent {
                action
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .font(.system(size: 18, weight: .semibold))
                    .adaptiveGlassButton(prominent: true).controlSize(.large).tint(Color.accentColor)
                    .foregroundStyle(.onAccent)
                    .frame(width: 52, height: 52)
            } else {
                action
                    .photoActionStyle(prominent: true)
            }
        }
        .disabled(openCamera == nil)
        .accessibilityIdentifier("camera.open")
    }
    private var action: some View {
        Button(
            String(localized: "camera.camera", defaultValue: "Camera"),
            systemImage: "camera"
        ) { openCamera?() }
        .buttonBorderShape(.circle)
        .accessibilityLabel(String(localized: "camera.camera", defaultValue: "Camera"))
    }
}

/// A small cached image. Status badges use one style in every gallery cell.
struct PhotoThumbnail: View {
    let photo: LibraryPhoto
    let images: LibraryImages
    var showsBadges = true
    var bypassesPause = false
    var placeholder: UIImage? = nil
    @State private var loaded: (id: UUID, image: UIImage)?
    @State private var failed = false
    private var displayedImage: UIImage? {
        if let loaded, loaded.id == photo.id { return loaded.image }
        return placeholder
    }
    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .overlay {
                if let image = displayedImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped().contentShape(.rect)
            .overlay(alignment: .topLeading) {
                if showsBadges && photo.isRAW { PhotoBadge(text: "RAW").padding(6) }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsBadges && photo.hasEdits {
                    PhotoBadge(symbol: PhotoBadge.editedSymbol).padding(6)
                }
            }
            .task(id: "\(photo.id)-\(photo.renderKey)") {
                failed = false
                if let cached = await images.cachedThumbnail(photo) {
                    guard !Task.isCancelled else { return }
                    loaded = (photo.id, UIImage(cgImage: cached))
                    return
                }
                do {
                    let frame = bypassesPause
                        ? try await images.cameraThumbnail(photo)
                        : try await images.image(photo, thumbnail: true)
                    try Task.checkCancellation()
                    loaded = (photo.id, UIImage(cgImage: frame))
                } catch { if !Task.isCancelled { failed = true } }
            }
            .onDisappear { loaded = nil }
            .accessibilityHidden(true)
    }
}

struct PhotoBadge: View {
    static let editedSymbol = "slider.horizontal.3"
    var text: String? = nil
    var symbol: String? = nil
    var compact = false
    var body: some View {
        Group {
            if let text {
                Text(text)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: compact ? 12 : 16, weight: .semibold))
            }
        }
        .accessibilityLabel(
            text ?? String(localized: "photo.edited", defaultValue: "Edited")
        )
        .accessibilityIdentifier(symbol == nil ? "photo.badge.raw" : "photo.badge.edited")
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .frame(minHeight: compact ? 14 : 18)
        .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 2 : 4)
        .foregroundStyle(.white).background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

struct LibraryThumbnail: View {
    let photo: LibraryPhoto
    let images: LibraryImages
    let selecting: Bool
    let selected: Bool
    var body: some View {
        PhotoThumbnail(photo: photo, images: images).aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2).symbolRenderingMode(.palette)
                        .foregroundStyle(
                            selected ? AnyShapeStyle(.onAccent) : AnyShapeStyle(.white),
                            selected ? Color.accentColor : .white)
                        .shadow(radius: 2).padding(7)
                }
            }
            .accessibilityHidden(true)
    }
}
