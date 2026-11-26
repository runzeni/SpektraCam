import SwiftUI
import UIKit

/// A photographer's loupe resting on the print. It shows the photograph at 100 % of the
/// rendered pixels (double-tap for 200 %), from a full-resolution frame when one is ready.
/// Drag it anywhere over the light table; it starts in the upper right.
struct DarkroomLoupe: View {
    static let viewportCoordinateSpace = "darkroom.viewport"
    /// The best available pixels for the photograph and where it sits on screen.
    let image: UIImage?
    var imageSubRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var canvasFill: Color? = nil
    var canvasFillRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    let center: CGPoint
    let imageFrame: CGRect
    let paperFrame: CGRect
    let bounds: CGSize
    var refining = false
    /// The table beside the print, so the lens shows what is really under it.
    var surround = Color(white: 0.86)
    var paper = Color.white
    /// Pixel width of the full-resolution frame. Magnification is fixed to it, so the view
    /// only sharpens when that frame replaces the preview; it never changes scale.
    var fullWidth: CGFloat? = nil
    /// Native-resolution pixels for the area under the lens, when they have been rendered.
    var patch: PhotoRenderer.Detail? = nil
    /// A clean print's easel blades (`Easel.mask`), over the picture.
    var blades: CGImage? = nil
    /// Reports the part of the photograph under the lens (unit coordinates of `imageFrame`).
    var onInspect: ((CGRect) -> Void)? = nil
    /// Normalized position in `paperFrame` unit coordinates (`nil` rests in the upper right).
    @Binding var anchor: CGPoint?
    @State private var doubled = false
    @GestureState private var dragOrigin: CGPoint? = nil
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let diameter: CGFloat = 156
    static let defaultAnchor = CGPoint(x: 0.86, y: 0.20)
    private let rim: CGFloat = 9

    static func resolvedCenter(anchor: CGPoint?, paperFrame: CGRect, bounds: CGSize) -> CGPoint {
        let r = diameter / 2
        if let anchor, paperFrame.width > 0, paperFrame.height > 0 {
            let raw = CGPoint(
                x: paperFrame.minX + anchor.x * paperFrame.width,
                y: paperFrame.minY + anchor.y * paperFrame.height
            )
            return CGPoint(
                x: min(max(raw.x, 0), max(0, bounds.width)),
                y: min(max(raw.y, 0), max(0, bounds.height))
            )
        }
        let raw: CGPoint
        if paperFrame.width > 0, paperFrame.height > 0 {
            raw = CGPoint(
                x: paperFrame.minX + defaultAnchor.x * paperFrame.width,
                y: paperFrame.minY + defaultAnchor.y * paperFrame.height
            )
        } else {
            raw = CGPoint(x: bounds.width - r - 10, y: r + 10)
        }
        let minX = min(r + 10, bounds.width / 2)
        let maxX = max(minX, bounds.width - r - 10)
        let minY = min(r + 10, bounds.height / 2)
        let maxY = max(minY, bounds.height - r - 10)
        return CGPoint(
            x: min(max(raw.x, minX), maxX),
            y: min(max(raw.y, minY), maxY)
        )
    }

    private var inspected: CGRect {
        let c = center, half = Self.diameter / 2 / zoom
        let w = max(imageFrame.width, 1), h = max(imageFrame.height, 1)
        return CGRect(x: (c.x - half - imageFrame.minX) / w, y: (c.y - half - imageFrame.minY) / h,
                      width: 2 * half / w, height: 2 * half / h)
    }
    private var pixelWidth: CGFloat {
        guard let image else { return 0 }
        return CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
    }
    /// Loupe points per screen point, so one rendered pixel covers one device pixel at 100 %.
    private var zoom: CGFloat {
        let nativePixels = fullWidth ?? (pixelWidth / max(imageSubRect.width, 0.1))
        let native = nativePixels / max(imageFrame.width, 1) / max(displayScale, 1)
        return max(native, 1.5) * (doubled ? 2 : 1)
    }

    var body: some View {
        let c = center, z = zoom, d = Self.diameter
        let paperOrigin = CGPoint(
            x: d / 2 + (paperFrame.minX - c.x) * z,
            y: d / 2 + (paperFrame.minY - c.y) * z
        )
        ZStack {
            ZStack(alignment: .topLeading) {
                surround
                // The same sheet as the preview, magnified: nothing past the paper's edge shows.
                PrintSheet(image: image, size: CGSize(width: paperFrame.width * z, height: paperFrame.height * z),
                           imageRect: CGRect(x: (imageFrame.minX - paperFrame.minX) * z, y: (imageFrame.minY - paperFrame.minY) * z,
                                             width: imageFrame.width * z, height: imageFrame.height * z),
                           imageSubRect: imageSubRect, canvasFill: canvasFill,
                           canvasFillRect: canvasFillRect,
                           paper: paper, blades: blades, patch: patch)
                    .offset(x: paperOrigin.x, y: paperOrigin.y)
            }
            .frame(width: d, height: d, alignment: .topLeading)
            .clipShape(Circle())
            // Lens: a soft vignette toward the barrel and a glancing highlight on the glass.
            Circle().fill(RadialGradient(colors: [.clear, .clear, .black.opacity(0.28)],
                                         center: .center, startRadius: 0, endRadius: d / 2))
            // The reflection of an overhead lamp: centred on the glass and held inside the barrel.
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: d * 0.66, height: d * 0.34).offset(y: -d * 0.24)
                .blendMode(.screen)
                .mask(Circle().inset(by: rim))
            // Barrel: brushed dark metal with a bright bevel.
            Circle().strokeBorder(AngularGradient(colors: [Color(white: 0.16), Color(white: 0.55), Color(white: 0.2),
                                                           Color(white: 0.42), Color(white: 0.14), Color(white: 0.16)],
                                                  center: .center), lineWidth: rim)
            Circle().inset(by: rim).strokeBorder(Color.black.opacity(0.65), lineWidth: 1)
            Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    if refining { ProgressView().controlSize(.mini).tint(.white) }
                    Text(verbatim: doubled ? "200 %" : "100 %")
                }
                .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, rim + 4)
            }
        }
        .frame(width: d, height: d)
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 6)
        .contentShape(Circle())
        .onChange(of: inspected, initial: true) { _, rect in onInspect?(rect) }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.viewportCoordinateSpace))
                .updating($dragOrigin) { _, state, _ in
                    if state == nil { state = c }
                }
                .onChanged { value in
                    let start = dragOrigin ?? c
                    let clamped = CGPoint(
                        x: min(max(start.x + value.translation.width, 0), max(0, bounds.width)),
                        y: min(max(start.y + value.translation.height, 0), max(0, bounds.height))
                    )
                    anchor = CGPoint(
                        x: (clamped.x - paperFrame.minX) / max(paperFrame.width, 1),
                        y: (clamped.y - paperFrame.minY) / max(paperFrame.height, 1)
                    )
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                doubled.toggle()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "darkroom.loupe", defaultValue: "Loupe"))
        .accessibilityValue(Text(verbatim: doubled ? "200 %" : "100 %"))
        .accessibilityHint(String(localized: "darkroom.loupe_hint", defaultValue: "Drag over the print to inspect it. Double-tap to change magnification."))
        .accessibilityAction(named: String(localized: "darkroom.loupe_zoom", defaultValue: "Change magnification")) { doubled.toggle() }
        .accessibilityIdentifier("darkroom.loupe")
    }
}

/// The print as it lies on the table: the sheet, and the picture placed on it, masked by the easel
/// blades and clipped to the sheet's edge. The Darkroom preview and the loupe draw this one view,
/// so the lens can never show anything the print does not (a borderless sheet crops the picture).
struct PrintSheet: View {
    let image: UIImage?
    /// The sheet, in points.
    let size: CGSize
    /// The picture (or film-edge canvas) on the sheet, in points; it may extend past the sheet.
    let imageRect: CGRect
    /// Sub-region of `imageRect` occupied by `image` while a surrounding film-edge rebate renders.
    var imageSubRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var canvasFill: Color? = nil
    var canvasFillRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    var paper = Color.white
    var blades: CGImage? = nil
    /// Native-resolution pixels over part of the picture (unit coordinates of `imageRect`).
    var patch: PhotoRenderer.Detail? = nil
    var body: some View {
        ZStack(alignment: .topLeading) {
            paper
            if let image {
                ZStack(alignment: .topLeading) {
                    if let canvasFill {
                        canvasFill
                            .frame(
                                width: canvasFillRect.width * imageRect.width,
                                height: canvasFillRect.height * imageRect.height
                            )
                            .offset(
                                x: canvasFillRect.minX * imageRect.width,
                                y: canvasFillRect.minY * imageRect.height
                            )
                    }
                    Image(uiImage: image).resizable().interpolation(.high)
                        .frame(
                            width: imageSubRect.width * imageRect.width,
                            height: imageSubRect.height * imageRect.height
                        )
                        .offset(
                            x: imageSubRect.minX * imageRect.width,
                            y: imageSubRect.minY * imageRect.height
                        )
                    if let patch {
                        Image(decorative: patch.image, scale: 1).resizable().interpolation(.high)
                            .frame(width: patch.rect.width * imageRect.width, height: patch.rect.height * imageRect.height)
                            .offset(x: patch.rect.minX * imageRect.width, y: patch.rect.minY * imageRect.height)
                    }
                }
                .frame(width: imageRect.width, height: imageRect.height, alignment: .topLeading)
                .modifier(BladeEdge(mask: blades))
                .offset(x: imageRect.minX, y: imageRect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}

/// The easel blades on a clean print (see `Easel.mask`): the picture fades to paper across their
/// penumbra and worn edges.
struct BladeEdge: ViewModifier {
    let mask: CGImage?
    func body(content: Content) -> some View {
        if let mask {
            // The mask is grey coverage (as Core Graphics clips with it); SwiftUI masks by alpha.
            content.mask { Image(decorative: mask, scale: 1).resizable().interpolation(.high).luminanceToAlpha() }
        } else {
            content
        }
    }
}
