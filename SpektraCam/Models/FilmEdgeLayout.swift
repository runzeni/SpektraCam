import CoreGraphics
import Foundation

/// A saved capture-support presentation. Nil in EditRecipe means Clean print.
/// `gate` describes the camera and holder (fixed per setup); `distress` how the film was handled.
nonisolated struct FilmEdgeLayout: Codable, Equatable, Sendable {
    enum Format: String, Codable, CaseIterable, Sendable { case film35, roll120 }
    var format = Format.film35
    enum Frame35: String, Codable, CaseIterable, Sendable {
        case full, half
        var title: String {
            switch self {
            case .full: String(localized: "darkroom.frame35.full", defaultValue: "Full")
            case .half: String(localized: "darkroom.frame35.half", defaultValue: "Half")
            }
        }
    }
    var frame35 = Frame35.full
    var apertureScale = 1.0
    static let apertureScaleRange = 0.96...1.04
    /// Physical film frame choice across 135 and 120 formats.
    enum FrameChoice: String, CaseIterable, Identifiable, Sendable {
        case film35Full, film35Half, roll645, roll66, roll67, roll69
        var id: Self { self }
        static let section135: [Self] = [.film35Full, .film35Half]
        static let section120: [Self] = [.roll645, .roll66, .roll67, .roll69]
        var format: Format {
            switch self {
            case .film35Full, .film35Half: .film35
            case .roll645, .roll66, .roll67, .roll69: .roll120
            }
        }
        var menuTitle: String {
            switch self {
            case .film35Full: String(localized: "crop.frame135.full", defaultValue: "Full frame")
            case .film35Half: String(localized: "crop.frame135.half", defaultValue: "Half frame")
            case .roll645: RollFrame.six45.title
            case .roll66: RollFrame.six6.title
            case .roll67: RollFrame.six7.title
            case .roll69: RollFrame.six9.title
            }
        }
        var closedTitle: String {
            "\(format == .film35 ? "135" : "120") · \(menuTitle)"
        }
    }
    var frameChoice: FrameChoice {
        switch format {
        case .film35:
            return frame35 == .half ? .film35Half : .film35Full
        case .roll120:
            switch rollFrame {
            case .six45: return .roll645
            case .six6: return .roll66
            case .six7: return .roll67
            case .six9: return .roll69
            }
        }
    }
    mutating func setFrameChoice(_ next: FrameChoice) {
        switch next {
        case .film35Full:
            format = .film35
            frame35 = .full
        case .film35Half:
            format = .film35
            frame35 = .half
        case .roll645:
            format = .roll120
            rollFrame = .six45
        case .roll66:
            format = .roll120
            rollFrame = .six6
        case .roll67:
            format = .roll120
            rollFrame = .six7
        case .roll69:
            format = .roll120
            rollFrame = .six9
        }
        applyCalibratedDefaultApertureScale(is135Full: next == .film35Full)
    }
    mutating func setFormat(_ next: Format) {
        guard format != next else { return }
        format = next
        applyCalibratedDefaultApertureScale(is135Full: next == .film35 && frame35 == .full)
    }
    mutating func setFrame35(_ next: Frame35) {
        guard frame35 != next else { return }
        frame35 = next
        applyCalibratedDefaultApertureScale(is135Full: format == .film35 && next == .full)
    }
    private mutating func applyCalibratedDefaultApertureScale(is135Full: Bool) {
        if !is135Full && abs(apertureScale - 1.015) < 1e-6 {
            apertureScale = 1.0
        } else if is135Full && abs(apertureScale - 1.0) < 1e-6 {
            apertureScale = 1.015
        }
    }
    enum SourcePerforations: String, Codable, CaseIterable, Sendable { case auto, stillKS, cineBH }
    var sourcePerforations = SourcePerforations.auto
    /// Motion-picture stock respooled for a still camera keeps BH-1866 holes (e.g. Ektachrome 100D
    /// 5294, Vision3). Off means the holes follow the chosen stock.
    var cinePerforations: Bool {
        get { sourcePerforations == .cineBH }
        set { sourcePerforations = newValue ? .cineBH : .auto }
    }
    func resolvedPerforation(filmID: String) -> FilmEdgeGeometry.Perforation {
        switch sourcePerforations {
        case .auto: .source(filmID: filmID)
        case .stillKS: .ks1870
        case .cineBH: .bh1866
        }
    }
    /// 120 frame sizes (nominal name, actual gate in mm). The 56 mm side always spans the film.
    enum RollFrame: String, Codable, CaseIterable, Sendable {
        case six45, six6, six7, six9
        var title: String {
            switch self { case .six45: "6 × 4.5"; case .six6: "6 × 6"; case .six7: "6 × 7"; case .six9: "6 × 9" }
        }
        /// Gate length along the film.
        var along: Double {
            switch self { case .six45: 41.5; case .six6: 56; case .six7: 69.5; case .six9: 84 }
        }
    }
    var rollFrame = RollFrame.six6
    /// The camera body's gate. Hasselblad V magazines cut two small V notches into the left edge,
    /// which print as ticks of picture in the rebate; a toy camera's moulded mask is soft and round.
    enum RollGate: String, Codable, CaseIterable, Sendable {
        case plain, hasselblad, toy
        var title: String {
            switch self {
            case .plain: String(localized: "darkroom.rollgate.plain", defaultValue: "Plain")
            case .hasselblad: "V"
            case .toy: "Holga"
            }
        }
    }
    var rollGate = RollGate.hasselblad
    var gate = FilmEdgeGate()
    var distress = FilmEdgeDistress()
    /// Enlarger print only: how large the projected frame is relative to the easel opening, set
    /// by raising or lowering the enlarger head. 100 % puts the blades on the frame edge; below,
    /// the opening shows a black band of rebate (at 90 % the holes start to show); above, the
    /// blades crop into the picture. The blades keep the frame's proportions.
    var printZoom = 0.93
    static let printZoomRange = 0.9...1.1
    /// Scan only: how much of the strip the scanner's crop takes in, relative to the frame. 100 %
    /// is the frame itself; lower shows the rebate, the holes and (for a negative in a holder) the
    /// holder's edge. A digital crop, so its edge is sharp.
    var scanZoom = 0.9
    static let scanZoomRange = 0.75...1.05
    /// Enlarger print: paper rendered around the easel opening, in fractions of the frame's long
    /// side; room for a hand-set blade's miss and its penumbra. The rest of the sheet is composited.
    static let easelMargin = 0.025
    /// The nominal easel opening inside an enlarger-print canvas of `size`, in unit coordinates.
    func easelFrame(canvas size: CGSize) -> CGRect {
        let halfLong = max(nominalGateAlong, nominalGateAcross) / 2 / printZoom
        let halfShort = min(nominalGateAlong, nominalGateAcross) / 2 / printZoom
        let margin = Self.easelMargin * max(nominalGateAlong, nominalGateAcross)
        let long = halfLong / (halfLong + margin), short = halfShort / (halfShort + margin)
        let (fx, fy) = size.width >= size.height ? (long, short) : (short, long)
        return CGRect(x: (1 - fx) / 2, y: (1 - fy) / 2, width: fx, height: fy)
    }
    /// Rebate shown beyond the frame on film (positive) or picture cropped (negative), in mm,
    /// at the frame's ends and along its sides.
    var easelBorder: (ends: Double, sides: Double) {
        (nominalGateAlong / 2 / printZoom - gateAlong / 2, nominalGateAcross / 2 / printZoom - gateAcross / 2)
    }
    /// A new film edge: Natural gate, calibrated 101.5% 135 full-frame aperture, Lab scan handling.
    static func newDefault(seed: UInt32 = UInt32.random(in: 1...UInt32.max)) -> Self {
        var layout = Self()
        layout.apertureScale = 1.015
        layout.distress.seed = seed
        layout.distress.apply(.lab)
        return layout
    }
    /// Deterministic read-only fallback for view getters that need defaults without generating a random seed.
    static let previewFallback: Self = newDefault(seed: 1)
    /// Nominal format gate along and across the film, in mm (carrier/easel/scan reference).
    var nominalGateAlong: Double { format == .film35 ? (frame35 == .half ? 18 : 36) : rollFrame.along }
    var nominalGateAcross: Double { format == .film35 ? 24 : 56 }
    /// Actual camera gate along and across the film, in mm.
    var gateAlong: Double { nominalGateAlong * apertureScale }
    var gateAcross: Double { nominalGateAcross * apertureScale }
    /// Long × short.
    var gateSize: CGSize { CGSize(width: max(gateAlong, gateAcross), height: min(gateAlong, gateAcross)) }
    var isSquare: Bool { gateAlong == gateAcross }
    var cropAspect: CropAspect {
        if format == .film35 { return frame35 == .half ? .fourThree : .threeTwo }
        switch rollFrame { case .six45: return .roll645; case .six6: return .rollSquare; case .six7: return .roll67; case .six9: return .threeTwo }
    }
    func gateTitle(portrait: Bool) -> String {
        func mm(_ v: Double) -> String {
            abs(v - v.rounded()) < 1e-4 ? String(Int(v.rounded())) : v.formatted(.number.precision(.fractionLength(0...2)))
        }
        let long = mm(gateSize.width), short = mm(gateSize.height)
        return isSquare ? "\(long) × \(short) mm" : portrait ? "\(short) × \(long) mm" : "\(long) × \(short) mm"
    }
    /// Resolution-independent physical source footprint covering the soft/worn/bulged aperture
    /// inside an upright image of `imageSize`, without clamping border pixels or mutating `CropSelection`.
    struct SourceSupport: Equatable, Sendable {
        let constrainedCrop: CropSelection
        let footprint: CGRect
        let visibleCropRect: CGRect
        let supportHalf: (x: Double, y: Double)
        let coverScale: Double
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.constrainedCrop == rhs.constrainedCrop && lhs.footprint == rhs.footprint
                && lhs.visibleCropRect == rhs.visibleCropRect
                && lhs.supportHalf.x == rhs.supportHalf.x && lhs.supportHalf.y == rhs.supportHalf.y
                && lhs.coverScale == rhs.coverScale
        }
    }
    func apertureSupportMarginMm() -> (along: Double, across: Double) {
        let d = FilmEdgeGeometry.resolve(self)
        let notched = format == .roll120 && rollGate == .hasselblad
        let pad = d.gateSoftness + d.gateWear + 0.12
        return (
            along: max(0, 0.15 * d.bulge) + (notched ? FilmEdgeGeometry.notchDepth : 0) + pad,
            across: max(0, 0.22 * d.bulge) + pad
        )
    }
    func sourceSupport(for crop: CropSelection, imageSize: CGSize) -> SourceSupport {
        let constrained = constrainedCrop(crop, imageSize: imageSize)
        let rect = constrained.normalizedRect.intersection(CropSelection.fullImage)
        guard imageSize.width > 0, imageSize.height > 0, !rect.isNull, !rect.isEmpty else {
            let portrait = gateAlong < gateAcross
            let gateHalfX = (portrait ? gateAcross : gateAlong) / 2
            let gateHalfY = (portrait ? gateAlong : gateAcross) / 2
            let margin = apertureSupportMarginMm()
            let marginX = portrait ? margin.across : margin.along
            let marginY = portrait ? margin.along : margin.across
            return SourceSupport(
                constrainedCrop: constrained, footprint: CropSelection.fullImage,
                visibleCropRect: CropSelection.fullImage,
                supportHalf: (gateHalfX + marginX, gateHalfY + marginY), coverScale: 1)
        }
        let cropPixelSize = CGSize(width: rect.width * imageSize.width, height: rect.height * imageSize.height)
        let portrait = (cropPixelSize.height > cropPixelSize.width) == (gateAlong >= gateAcross)
        let gateHalfX = (portrait ? gateAcross : gateAlong) / 2
        let gateHalfY = (portrait ? gateAlong : gateAcross) / 2
        let margin = apertureSupportMarginMm()
        let marginX = portrait ? margin.across : margin.along
        let marginY = portrait ? margin.along : margin.across
        let relX = marginX / max(gateHalfX, 1e-6)
        let relY = marginY / max(gateHalfY, 1e-6)
        let availHalfX = min(rect.midX, 1 - rect.midX)
        let availHalfY = min(rect.midY, 1 - rect.midY)
        let coverScale = max(
            1.0,
            (rect.width / 2) * (1 + relX) / max(availHalfX, 1e-9),
            (rect.height / 2) * (1 + relY) / max(availHalfY, 1e-9))
        let halfW = min(availHalfX, (rect.width / 2) * (1 + relX) / coverScale)
        let halfH = min(availHalfY, (rect.height / 2) * (1 + relY) / coverScale)
        let footprint = CGRect(x: rect.midX - halfW, y: rect.midY - halfH, width: 2 * halfW, height: 2 * halfH)
        let visHalfW = (rect.width / 2) / coverScale
        let visHalfH = (rect.height / 2) / coverScale
        let visibleCropRect = CGRect(
            x: rect.midX - visHalfW, y: rect.midY - visHalfH,
            width: 2 * visHalfW, height: 2 * visHalfH)
        return SourceSupport(
            constrainedCrop: constrained, footprint: footprint, visibleCropRect: visibleCropRect,
            supportHalf: (gateHalfX + marginX, gateHalfY + marginY), coverScale: coverScale)
    }
    func constrainedCrop(_ crop: CropSelection, imageSize: CGSize) -> CropSelection {
        guard imageSize.width > 0, imageSize.height > 0 else { return crop }
        var result = crop
        let current = crop.normalizedRect
        let portrait = !isSquare && current.width * imageSize.width < current.height * imageSize.height
        result.constrain(to: cropAspect, orientation: portrait ? .portrait : .landscape,
                         imageAspect: imageSize.width / imageSize.height)
        return result
    }
    /// Integral source pixels may differ by at most one rounded pixel from the exact gate.
    func matchesGate(_ imageSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0 else { return false }
        let ratio = gateSize.width / gateSize.height
        return abs(max(imageSize.width, imageSize.height) - min(imageSize.width, imageSize.height) * ratio) <= ratio
    }
    init() {}
    enum CodingKeys: String, CodingKey {
        case format, frame35, apertureScale, cinePerforations, sourcePerforations, rollFrame, rollGate, gate, distress, printZoom, scanZoom
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if format != .film35 { try c.encode(format, forKey: .format) }
        if frame35 != .full { try c.encode(frame35, forKey: .frame35) }
        if abs(apertureScale - 1.0) > 1e-9 { try c.encode(apertureScale, forKey: .apertureScale) }
        if sourcePerforations == .cineBH { try c.encode(true, forKey: .cinePerforations) }
        if sourcePerforations != .auto { try c.encode(sourcePerforations, forKey: .sourcePerforations) }
        if rollFrame != .six6 { try c.encode(rollFrame, forKey: .rollFrame) }
        if rollGate != .hasselblad { try c.encode(rollGate, forKey: .rollGate) }
        if gate != FilmEdgeGate() { try c.encode(gate, forKey: .gate) }
        try c.encode(distress, forKey: .distress)
        try c.encode(printZoom, forKey: .printZoom)
        if abs(scanZoom - 0.9) > 1e-9 { try c.encode(scanZoom, forKey: .scanZoom) }
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decodeIfPresent(Format.self, forKey: .format) ?? .film35
        frame35 = try values.decodeIfPresent(Frame35.self, forKey: .frame35) ?? .full
        let decodedScale = try values.decodeIfPresent(Double.self, forKey: .apertureScale) ?? 1.0
        apertureScale = decodedScale.isFinite
            ? min(max(decodedScale, Self.apertureScaleRange.lowerBound), Self.apertureScaleRange.upperBound)
            : 1.0
        if let explicit = try values.decodeIfPresent(SourcePerforations.self, forKey: .sourcePerforations) {
            sourcePerforations = explicit
        } else {
            let cine = try values.decodeIfPresent(Bool.self, forKey: .cinePerforations) ?? false
            sourcePerforations = cine ? .cineBH : .auto
        }
        rollFrame = try values.decodeIfPresent(RollFrame.self, forKey: .rollFrame) ?? .six6
        rollGate = try values.decodeIfPresent(RollGate.self, forKey: .rollGate) ?? .hasselblad
        gate = (try? values.decodeIfPresent(FilmEdgeGate.self, forKey: .gate)) ?? FilmEdgeGate()
        distress = try values.decodeIfPresent(FilmEdgeDistress.self, forKey: .distress) ?? FilmEdgeDistress()
        if distress.leakShape == .burn,
           let dc = try? values.nestedContainer(keyedBy: FilmEdgeDistress.CodingKeys.self, forKey: .distress),
           !dc.contains(.burnCoverage)
        {
            let ha = nominalGateAlong / 2 + (format == .film35 ? 1.0 : 2.0)
            let ht = nominalGateAcross / 2 + (format == .film35 ? 1.35 : 2.0)
            let perim = 4 * (ha + ht)
            let s = (distress.leakPosition - floor(distress.leakPosition)) * perim
            let alongEntry = (s >= 2 * ha && s < 2 * ha + 2 * ht) || (s >= 4 * ha + 2 * ht)
            let rebate = alongEntry ? (format == .film35 ? 1.0 : 2.0) : (format == .film35 ? 1.35 : 2.0)
            let span = alongEntry ? nominalGateAlong : nominalGateAcross
            distress.burnCoverage = min(max((distress.leakSize - rebate) / max(span, 1), 0), 1)
        }
        let zoom = try values.decodeIfPresent(Double.self, forKey: .printZoom) ?? 0.93
        printZoom = zoom.isFinite ? min(max(zoom, Self.printZoomRange.lowerBound), Self.printZoomRange.upperBound) : 0.93
        let scan = try values.decodeIfPresent(Double.self, forKey: .scanZoom) ?? 0.9
        scanZoom = scan.isFinite ? min(max(scan, Self.scanZoomRange.lowerBound), Self.scanZoomRange.upperBound) : 0.9
    }
}

/// Preserves the photographer's pre-gate framing across successive film-frame choices so
/// switching 135 -> 120 6x6 -> 135 never double-trims or zooms in silently.
nonisolated struct FilmFrameCropSession: Equatable, Sendable {
    var baseCrop: CropSelection
    var preferredOrientation: CropOrientation?
    var hasManualAdjustment: Bool

    init(baseCrop: CropSelection, isPreGateBase: Bool) {
        self.baseCrop = baseCrop
        self.hasManualAdjustment = !isPreGateBase
        switch baseCrop.orientation {
        case .portrait, .landscape:
            self.preferredOrientation = baseCrop.orientation
        case .automatic:
            self.preferredOrientation = nil
        }
    }

    func crop(for layout: FilmEdgeLayout, imageSize: CGSize) -> CropSelection {
        guard imageSize.width > 0, imageSize.height > 0 else { return baseCrop }
        var result = baseCrop
        if layout.isSquare {
            result.constrain(
                to: layout.cropAspect, orientation: .landscape,
                imageAspect: imageSize.width / imageSize.height)
            return result
        }
        let rect = baseCrop.normalizedRect
        let orientation = preferredOrientation
            ?? (rect.width * imageSize.width < rect.height * imageSize.height ? .portrait : .landscape)
        result.constrain(
            to: layout.cropAspect, orientation: orientation,
            imageAspect: imageSize.width / imageSize.height)
        return result
    }

    mutating func recordManualCrop(_ updated: CropSelection) {
        baseCrop = updated
        hasManualAdjustment = true
        if updated.orientation != .automatic {
            preferredOrientation = updated.orientation
        }
    }

    mutating func setOrientation(
        _ orientation: CropOrientation, currentCrop: CropSelection,
        layout: FilmEdgeLayout, imageSize: CGSize
    ) -> CropSelection {
        preferredOrientation = orientation
        guard imageSize.width > 0, imageSize.height > 0 else { return currentCrop }
        if !hasManualAdjustment {
            return crop(for: layout, imageSize: imageSize)
        }
        var next = currentCrop
        next.aspect = layout.cropAspect
        next.setOrientation(orientation, imageAspect: imageSize.width / imageSize.height)
        baseCrop = next
        return next
    }

    mutating func rotateLeft(imageAspect: CGFloat) {
        baseCrop.rotateLeft(imageAspect: imageAspect)
        if let preferredOrientation {
            self.preferredOrientation = preferredOrientation == .portrait ? .landscape : .portrait
        }
    }

    mutating func flipHorizontal() { baseCrop.flipHorizontal() }
    mutating func flipVertical() { baseCrop.flipVertical() }

    mutating func reset(layout: FilmEdgeLayout, imageSize: CGSize) -> CropSelection {
        baseCrop = CropSelection()
        preferredOrientation = nil
        hasManualAdjustment = false
        return crop(for: layout, imageSize: imageSize)
    }
}

/// The camera aperture and the scanner holder: properties of the equipment, not of handling.
/// Softness is the gate penumbra (≈ gap / 2N); wear roughens the aperture edge; the holder edge is
/// out of focus (crisp core plus a faint tail) with abraded specks; tilt and bulge are the
/// setup's inherent misalignment and film flatness. Engineering values, not camera measurements.
nonisolated struct FilmEdgeGate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case precise, natural, loose
        var title: String {
            switch self {
            case .precise: String(localized: "darkroom.gate.precise", defaultValue: "Precise")
            case .natural: String(localized: "darkroom.gate.natural", defaultValue: "Natural")
            case .loose: String(localized: "darkroom.gate.loose", defaultValue: "Loose")
            }
        }
    }
    var softness = 0.03
    var wear = 0.02
    var holderBlur = 0.1
    var holderDetail = 0.35
    /// Legacy pre-v5 gate misalignment (degrees) retained for older recipes.
    var tilt = 0.0
    /// Legacy pre-v5 film flatness offset retained for older recipes.
    var bulge = 0.0

    init() {}
    init(_ kind: Kind) {
        switch kind {
        case .precise: softness = 0.03; wear = 0.02; holderBlur = 0.06; holderDetail = 0.2; tilt = 0; bulge = 0
        case .natural: break
        case .loose: softness = 0.05; wear = 0.04; holderBlur = 0.16; holderDetail = 0.5; tilt = 0; bulge = 0
        }
    }
    var kind: Kind? {
        Kind.allCases.first { candidate in
            let ref = Self(candidate)
            guard softness == ref.softness, wear == ref.wear,
                holderBlur == ref.holderBlur, holderDetail == ref.holderDetail
            else { return false }
            if tilt == 0 && bulge == 0 { return true }
            switch candidate {
            case .precise: return false
            case .natural: return tilt == 0.2 && bulge == 0.25
            case .loose: return tilt == 0.5 && bulge == 0.6
            }
        }
    }
    enum CodingKeys: String, CodingKey { case softness, wear, holderBlur, holderDetail, tilt, bulge }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        softness = try v.decodeIfPresent(Double.self, forKey: .softness) ?? 0.03
        wear = try v.decodeIfPresent(Double.self, forKey: .wear) ?? 0.02
        holderBlur = try v.decodeIfPresent(Double.self, forKey: .holderBlur) ?? 0.1
        holderDetail = try v.decodeIfPresent(Double.self, forKey: .holderDetail) ?? 0.35
        tilt = try v.decodeIfPresent(Double.self, forKey: .tilt) ?? 0.2
        bulge = try v.decodeIfPresent(Double.self, forKey: .bulge) ?? 0.25
    }
}

/// Procedural, seeded imperfections from handling, in physical film millimetres. Every field is
/// placed at the stage where its mechanism acts (see Research/Darkroom-v0.3/DISTRESS-AND-LEAKS.md):
/// leaks and fog are exposure before development; scratches thin the developed dye or scatter
/// light; dust and the carrier act where the film is printed or scanned. `amount` scales only
/// intensities. These ranges are engineering choices, not calibrated measurements.
///
/// The optics fields below (`gateSoftness`, `gateWear`, `carrierBlur`, `carrierDetail`,
/// `carrierTail`, `fogDepth`, `perforationLeak`) are not saved: `FilmEdgeGeometry` resolves them
/// from the gate and from edge fog, so one parameter set feeds the CPU reference and Metal.
nonisolated struct FilmEdgeDistress: Codable, Equatable, Sendable {
    static let algorithmRevision = 5
    /// Through the lens (front) light is gated with the scene and reaches the top, blue-sensitive
    /// layer first; a back/door-seal leak bypasses the gate and enters through the base.
    enum LeakKind: String, Codable, CaseIterable, Sendable { case back, front }
    /// Burn: the fogged start of a roll, exposed past saturation, with a narrow wavy boundary.
    enum LeakShape: String, Codable, CaseIterable, Sendable {
        case glow, streak, flare, burn
        var title: String {
            switch self {
            case .glow: String(localized: "darkroom.distress.shape_glow", defaultValue: "Glow")
            case .streak: String(localized: "darkroom.distress.shape_streak", defaultValue: "Streak")
            case .flare: String(localized: "darkroom.distress.shape_flare", defaultValue: "Flare")
            case .burn: String(localized: "darkroom.distress.shape_burn", defaultValue: "Burn")
            }
        }
    }
    var revision = Self.algorithmRevision
    var seed: UInt32 = 1
    var amount = 1.0
    /// Signed film-loading tilt (degrees) and film curl (−1 … +1) owned by Distress in v5+.
    var tilt = 0.0
    var bulge = 0.0
    /// Natural, always-present hole differences: punch tolerance between holes and the rim where
    /// light piped in through the cut hole wall — a bright streak on the picture side.
    var holeVariation = 0.25
    var carrierRoughness = 0.0
    /// Unmasked enlarger light reflected by a bare-metal carrier edge onto the paper (prints only).
    var carrierReflection = 0.0
    /// Printed on an enlarger (colour or black-and-white, the same optics) rather than scanned:
    /// the easel's straight blades mask the paper, and `FilmEdgeLayout.printZoom` decides how
    /// much rebate they show. Set from the edge type (a negative print), not by hand; see
    /// `EditRecipe.renderedFilmEdgeLayout`.
    var enlargerPrint = false
    /// Set from the edge type, not saved: a negative scanned in a holder (direct or inverted), and
    /// a negative scan inverted to a positive. Positive scans are direct camera scans, no holder.
    var scanHolder = false
    var invertedScan = false
    var edgeFog = 0.0
    var leak = 0.0
    var leakKind = LeakKind.back
    var leakShape = LeakShape.glow
    var leakSize = 8.0
    /// Normalized strip coverage for `.burn` (0 = suppressed, 0.35 = 35% of picture span, 1 = full strip).
    var burnCoverage = 0.35
    var leakPosition = 0.3
    /// Felt-plush lip irregularity on a roll-start burn: 0 smooth lip … 0.5 cassette plush … 1 frayed tufts.
    var burnTexture = 0.5
    /// −1 cool (front, blue layer first) … 0 neutral … +1 warm (base, red layer first).
    var warmth = 0.6
    var dust = 0.0
    var scratches = 0.0
    /// Rails and sprockets touch only the rebate, so scratches stay there by default.
    /// Releasing the clamp lets gate debris drag scratches across the picture as well.
    var scratchesInImage = false

    // Resolved by FilmEdgeGeometry; not saved and not shown as distress controls.
    var gateSoftness = 0.03
    var gateWear = 0.02
    var carrierBlur = 0.1
    var carrierDetail = 0.35
    var carrierTail = 0.05
    var carrierTailWidth = 0.12
    var carrierScale = 1.2
    /// Inside corner of the opening: a milled holder is tight, a hand-filed carrier rounder.
    var carrierCorner = 0.2
    /// Slow wander of the outline around the frame (mm): no hand-filed side is straight or
    /// parallel, so the black border changes width along its length.
    var carrierWave = 0.02
    var fogDepth = 1.5
    var perforationLeak = 0.0

    var isLeakEnabled: Bool { leak > 1e-6 }
    mutating func toggleLeakShape(_ shape: LeakShape) {
        if isLeakEnabled && leakShape == shape {
            leak = 0
        } else {
            leakShape = shape
            leak = 0.30
        }
    }

    static let ranges: [WritableKeyPath<Self, Double>: ClosedRange<Double>] = [
        \.amount: 0...2, \.tilt: -3...3, \.bulge: -1...1, \.holeVariation: 0...1,
        \.carrierRoughness: 0...0.5, \.carrierReflection: 0...1, \.edgeFog: 0...1,
        \.leak: 0...1, \.leakSize: 2...30, \.burnCoverage: 0...1, \.leakPosition: 0...1, \.burnTexture: 0...1,
        \.warmth: -1...1, \.dust: 0...1, \.scratches: 0...1,
    ]
    static func defaultWarmth(_ kind: LeakKind) -> Double { kind == .front ? -0.4 : 0.6 }

    /// Independent deterministic signed tilt within ±0.25° in 0.05° steps.
    static func labTilt(seed: UInt32) -> Double {
        let h = FilmEdgeGeometry.streamSeed(seed, 71)
        let sign: Double = (h & 1) == 0 ? 1 : -1
        let steps = 1 + Int((h >> 1) % 5)  // 0.05° ... 0.25° in 0.05° steps
        return sign * Double(steps * 5) / 100.0
    }

    /// Independent deterministic signed film curl within ±20% in 1% steps.
    static func labBulge(seed: UInt32) -> Double {
        let h = FilmEdgeGeometry.streamSeed(seed, 72)
        let sign: Double = (h & 1) == 0 ? 1 : -1
        let percent = 4 + Int((h >> 1) % 17)  // 4% ... 20% in 1% steps
        return sign * Double(percent) / 100.0
    }

    enum Preset: String, CaseIterable, Sendable {
        case clean, lab, worn, leaky
        var title: String {
            switch self {
            case .clean: String(localized: "darkroom.distress.clean", defaultValue: "Clean")
            case .lab: String(localized: "darkroom.distress.lab", defaultValue: "Lab scan")
            case .worn: String(localized: "darkroom.distress.worn", defaultValue: "Old camera")
            case .leaky: String(localized: "darkroom.distress.leaky", defaultValue: "Light leak")
            }
        }
        /// Clean keeps natural 25% hole variation with zero added handling damage; Lab scan adds seeded
        /// ±0.25° tilt, ±20% curl, 20% edge fog and 10% rebate scratches; Old camera adds 50% hole
        /// variation, dust, full scratches, crooked load and curl; Light leak adds a roll-start burn.
        func values(seed: UInt32) -> FilmEdgeDistress {
            var d = FilmEdgeDistress()
            d.seed = seed
            switch self {
            case .clean: break
            case .lab:
                d.tilt = FilmEdgeDistress.labTilt(seed: seed)
                d.bulge = FilmEdgeDistress.labBulge(seed: seed)
                d.edgeFog = 0.20
                d.scratches = 0.10
            case .worn:
                d.tilt = 1; d.bulge = 0.3; d.carrierRoughness = 0.08; d.holeVariation = 0.5
                d.edgeFog = 0.3; d.leak = 0.3; d.leakSize = 10; d.warmth = 0.7
                d.dust = 0.4; d.scratches = 1
            case .leaky:
                d.scratches = 0.15; d.edgeFog = 0.35; d.leak = 0.7; d.leakShape = .burn; d.burnCoverage = 0.35; d.warmth = 0.7
            }
            return d
        }
        var values: FilmEdgeDistress { values(seed: 1) }
        var legacyValues: FilmEdgeDistress {
            var d = FilmEdgeDistress()
            d.revision = 4
            d.holeVariation = 0.5
            switch self {
            case .clean: break
            case .lab: d.scratches = 0.15; d.edgeFog = 0.06
            case .worn:
                d.tilt = 1; d.bulge = 0.3; d.carrierRoughness = 0.08; d.holeVariation = 0.8
                d.edgeFog = 0.3; d.leak = 0.3; d.leakSize = 10; d.warmth = 0.7
                d.dust = 0.4; d.scratches = 1
            case .leaky:
                d.scratches = 0.15; d.edgeFog = 0.35; d.leak = 0.7; d.leakShape = .burn; d.burnCoverage = 0.35; d.warmth = 0.7
            }
            return d
        }
    }
    /// Seed, amount, leak position and the scratch clamp are personal choices, not part of a preset.
    var preset: Preset? {
        Preset.allCases.first { candidate in
            let ref = revision < 5 ? candidate.legacyValues : candidate.values(seed: seed)
            return ref.comparable == comparable
        }
    }
    private var comparable: Self {
        var copy = self
        copy.seed = 1; copy.amount = 1; copy.leakPosition = 0.3; copy.scratchesInImage = false
        copy.revision = Self.algorithmRevision
        if copy.leak <= 1e-6 {
            copy.leak = 0
            copy.leakShape = .glow
            copy.leakKind = .back
            copy.leakSize = 8.0
            copy.burnCoverage = 0.35
            copy.burnTexture = 0.5
            copy.warmth = 0.6
        }
        return copy
    }
    mutating func apply(_ preset: Preset) {
        let keep = (seed, amount, leakPosition, scratchesInImage)
        self = preset.values(seed: seed)
        revision = Self.algorithmRevision
        (seed, amount, leakPosition, scratchesInImage) = keep
    }
    static let cleanPrintFallback = FilmEdgeDistress()
    var hasCleanPrintEffects: Bool {
        let e = effective
        return e.edgeFog > 1e-6 || e.leak > 1e-6 || e.dust > 1e-6
            || (e.scratches > 1e-6 && scratchesInImage)
    }
    var isUntouchedDefaultLab: Bool {
        (preset == .lab || preset == .clean)
            && abs(amount - 1.0) <= 1e-6
            && !scratchesInImage
    }
    var cleanPrintPreset: Preset? {
        Preset.allCases.first { candidate in
            let ref = revision < 5 ? candidate.legacyValues : candidate.values(seed: seed)
            return ref.cleanPrintComparable == cleanPrintComparable
        }
    }
    private var cleanPrintComparable: Self {
        var copy = comparable
        copy.tilt = 0
        copy.bulge = 0
        copy.holeVariation = 0
        copy.carrierRoughness = 0
        copy.carrierReflection = 0
        return copy
    }
    mutating func applyCleanPrintPreset(_ preset: Preset) {
        apply(preset)
        tilt = 0
        bulge = 0
        holeVariation = 0
        carrierRoughness = 0
    }
    mutating func transferSurface(from other: FilmEdgeDistress) {
        seed = other.seed
        amount = other.amount
        edgeFog = other.edgeFog
        leak = other.leak
        leakKind = other.leakKind
        leakShape = other.leakShape
        leakSize = other.leakSize
        burnCoverage = other.burnCoverage
        leakPosition = other.leakPosition
        burnTexture = other.burnTexture
        warmth = other.warmth
        dust = other.dust
        scratches = other.scratches
        scratchesInImage = other.scratchesInImage
    }
    mutating func rerollHandling(seed newSeed: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        let resolvedSeed = newSeed == seed ? (newSeed &+ 1 == 0 ? 1 : newSeed &+ 1) : newSeed
        seed = resolvedSeed
        tilt = Self.labTilt(seed: resolvedSeed)
        bulge = Self.labBulge(seed: resolvedSeed)
    }
    /// Reroll the pattern seed while keeping Lab's seed-derived handling tied to its preset identity,
    /// and leaving manually edited or Custom handling values untouched.
    mutating func rerollPattern(seed newSeed: UInt32) {
        let current = preset
        seed = newSeed
        if current == .lab && revision >= 5 {
            tilt = Self.labTilt(seed: newSeed)
            bulge = Self.labBulge(seed: newSeed)
        }
    }
    /// Reroll the active light leak or roll-start burn (`烧片头`), enabling it if currently off,
    /// while preserving crooked-loading tilt and film curl.
    mutating func rerollLeak(seed newSeed: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        if !isLeakEnabled { leak = 0.30 }
        let resolvedSeed = newSeed == seed ? (newSeed &+ 1 == 0 ? 1 : newSeed &+ 1) : newSeed
        seed = resolvedSeed
        var h = FilmEdgeGeometry.streamSeed(resolvedSeed, 79)
        func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
        if leakShape == .burn {
            let useOpposite = next() < 0.65
            let currentlySecondEnd = leakPosition >= 0.65
            let endCenter = (useOpposite ? !currentlySecondEnd : currentlySecondEnd) ? 0.90 : 0.40
            var candidate = ((endCenter + (next() * 2 - 1) * 0.04) * 100).rounded() / 100
            if abs(candidate - leakPosition) < 0.015 {
                candidate = candidate < endCenter ? endCenter + 0.03 : endCenter - 0.03
            }
            leakPosition = candidate
            burnCoverage = ((0.18 + 0.44 * next()) * 100).rounded() / 100
            burnTexture = ((0.20 + 0.65 * next()) * 100).rounded() / 100
        } else {
            let delta = 0.18 + 0.64 * next()
            let wrapped = leakPosition + delta - floor(leakPosition + delta)
            leakPosition = (wrapped * 100).rounded() / 100
            leakSize = ((5.0 + 13.0 * next()) * 2).rounded() / 2
        }
    }
    /// Intensities after the global Amount. Hole variation, sizes and colour are unchanged.
    var effective: Self {
        var e = self
        let a = max(0, amount)
        e.tilt = min(max(tilt * a, -3), 3)
        e.bulge = min(max(bulge * a, -1.5), 1.5)
        e.carrierRoughness *= a
        e.carrierReflection = min(1, carrierReflection * a)
        e.edgeFog = min(1, edgeFog * a); e.leak = min(1, leak * a)
        e.dust = min(1, dust * a); e.scratches = min(1, scratches * a)
        return e
    }

    init() {}
    enum CodingKeys: String, CodingKey {
        case revision, seed, amount, tilt, bulge, holeVariation, carrierRoughness, carrierReflection, enlargerPrint,
            edgeFog, leak, leakKind, leakShape, leakSize, burnCoverage, leakPosition, burnTexture, warmth, dust, scratches, scratchesInImage
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(revision, forKey: .revision)
        try c.encode(seed, forKey: .seed)
        if abs(amount - 1.0) > 1e-9 { try c.encode(amount, forKey: .amount) }
        if abs(tilt) > 1e-9 { try c.encode(tilt, forKey: .tilt) }
        if abs(bulge) > 1e-9 { try c.encode(bulge, forKey: .bulge) }
        try c.encode(holeVariation, forKey: .holeVariation)
        if abs(carrierRoughness) > 1e-9 { try c.encode(carrierRoughness, forKey: .carrierRoughness) }
        if abs(carrierReflection) > 1e-9 { try c.encode(carrierReflection, forKey: .carrierReflection) }
        if enlargerPrint { try c.encode(true, forKey: .enlargerPrint) }
        if abs(edgeFog) > 1e-9 { try c.encode(edgeFog, forKey: .edgeFog) }
        if abs(leak) > 1e-9 { try c.encode(leak, forKey: .leak) }
        if leakKind != .back { try c.encode(leakKind, forKey: .leakKind) }
        if leakShape != .glow { try c.encode(leakShape, forKey: .leakShape) }
        if abs(leakSize - 8.0) > 1e-9 { try c.encode(leakSize, forKey: .leakSize) }
        if leakShape == .burn || abs(burnCoverage - 0.35) > 1e-9 {
            try c.encode(burnCoverage, forKey: .burnCoverage)
        }
        if abs(leakPosition - 0.3) > 1e-9 { try c.encode(leakPosition, forKey: .leakPosition) }
        if abs(burnTexture - 0.5) > 1e-9 { try c.encode(burnTexture, forKey: .burnTexture) }
        if abs(warmth - 0.6) > 1e-9 { try c.encode(warmth, forKey: .warmth) }
        if abs(dust) > 1e-9 { try c.encode(dust, forKey: .dust) }
        if abs(scratches) > 1e-9 { try c.encode(scratches, forKey: .scratches) }
        if scratchesInImage { try c.encode(true, forKey: .scratchesInImage) }
    }
    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        let base = Self()
        func n(_ key: CodingKeys, _ path: KeyPath<Self, Double>) throws -> Double {
            try v.decodeIfPresent(Double.self, forKey: key) ?? base[keyPath: path]
        }
        revision = try v.decodeIfPresent(Int.self, forKey: .revision) ?? 4
        seed = try v.decodeIfPresent(UInt32.self, forKey: .seed) ?? 1
        amount = try n(.amount, \.amount)
        tilt = try n(.tilt, \.tilt)
        bulge = try n(.bulge, \.bulge)
        holeVariation = try v.decodeIfPresent(Double.self, forKey: .holeVariation)
            ?? (revision < 5 ? 0.5 : base.holeVariation)
        carrierRoughness = try n(.carrierRoughness, \.carrierRoughness)
        carrierReflection = try n(.carrierReflection, \.carrierReflection)
        enlargerPrint = try v.decodeIfPresent(Bool.self, forKey: .enlargerPrint) ?? false
        edgeFog = try n(.edgeFog, \.edgeFog)
        leak = try n(.leak, \.leak)
        leakKind = (try? v.decodeIfPresent(LeakKind.self, forKey: .leakKind)) ?? .back
        leakShape = (try? v.decodeIfPresent(LeakShape.self, forKey: .leakShape)) ?? .glow
        leakSize = try n(.leakSize, \.leakSize)
        if let decodedCoverage = try v.decodeIfPresent(Double.self, forKey: .burnCoverage) {
            burnCoverage = decodedCoverage.isFinite ? min(max(decodedCoverage, 0), 1) : base.burnCoverage
        } else if leakShape == .burn {
            burnCoverage = min(max((leakSize - 1.2) / 36.0, 0), 1)
        } else {
            burnCoverage = base.burnCoverage
        }
        leakPosition = try n(.leakPosition, \.leakPosition)
        burnTexture = min(max(try n(.burnTexture, \.burnTexture), 0), 1)
        warmth = try n(.warmth, \.warmth)
        dust = try n(.dust, \.dust)
        scratches = try n(.scratches, \.scratches)
        scratchesInImage = try v.decodeIfPresent(Bool.self, forKey: .scratchesInImage) ?? false
    }
}

/// Integer hashing and value noise shared bit-for-bit with FilmPipeline.metalSource.
nonisolated enum FilmEdgeNoise {
    static func hash(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16; x = x &* 0x7feb352d
        x ^= x >> 15; x = x &* 0x846ca68b
        x ^= x >> 16
        return x
    }
    static func hash(_ i: Int32, _ j: Int32, _ seed: UInt32) -> UInt32 {
        hash((UInt32(bitPattern: i) &* 0x8da6b343) ^ hash((UInt32(bitPattern: j) &* 0xd8163841) ^ seed))
    }
    static func unit(_ h: UInt32) -> Double { Double(h >> 8) / 16_777_216 }
    /// C¹ value noise in [-1, 1]; continuous across lattice cells, so float/double floor
    /// disagreements on a boundary cannot create a visible seam.
    static func value(_ x: Double, _ y: Double, _ seed: UInt32) -> Double {
        let fx = floor(x), fy = floor(y)
        let tx = x - fx, ty = y - fy
        let ux = tx * tx * (3 - 2 * tx), uy = ty * ty * (3 - 2 * ty)
        let ix = Int32(clamping: Int(fx)), iy = Int32(clamping: Int(fy))
        let a = unit(hash(ix, iy, seed)), b = unit(hash(ix &+ 1, iy, seed))
        let c = unit(hash(ix, iy &+ 1, seed)), d = unit(hash(ix &+ 1, iy &+ 1, seed))
        return ((a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy) * 2 - 1
    }
    /// C¹ 1D value noise in [-1, 1]; matches `fe_value1` in FilmPipeline.metalSource.
    static func value1D(_ x: Double, _ seed: UInt32) -> Double {
        let fx = floor(x)
        let tx = x - fx
        let ux = tx * tx * (3 - 2 * tx)
        let ix = Int32(clamping: Int(fx))
        let a = unit(hash(ix, 0, seed)), b = unit(hash(ix &+ 1, 0, seed))
        return (a + (b - a) * ux) * 2 - 1
    }
    /// Fast logistic sigmoid 1 / (1 + exp(x)) using a 4th-power degree-3 Padé/Taylor polynomial.
    static func fastSigmoid(_ x: Double) -> Double {
        let clamped = min(max(x, -16), 16)
        let u = abs(clamped) * 0.25
        let q = 1 + u * (1 + u * (0.5 + u * 0.16666667))
        let q2 = q * q
        let e = q2 * q2
        return clamped >= 0 ? 1 / (1 + e) : e / (1 + e)
    }
    /// Fraction of a disc of radius r inside a straight edge at signed distance d (d > 0 outside).
    /// Unlike a Gaussian, a geometric penumbra has no tails.
    static func penumbra(_ d: Double, _ r: Double) -> Double {
        let u = min(max(d / max(r, 1e-9), -1), 1)
        return 0.5 - (asin(u) + u * (1 - u * u).squareRoot()) / .pi
    }
    /// Seeded unevenness of a cut edge in [-1, 1], the same profile for the camera gate and the
    /// easel blades: a broad wander (0.9 mm) and a fine tooth (0.16 mm), in film millimetres.
    static func wear(_ x: Double, _ y: Double, _ broad: UInt32, _ fine: UInt32) -> Double {
        0.65 * value(x / 0.9, y / 0.9, broad) + 0.35 * value(x / 0.16, y / 0.16, fine)
    }
    static func box(_ px: Double, _ py: Double, _ hx: Double, _ hy: Double, _ r: Double) -> Double {
        let qx = abs(px) - (hx - r), qy = abs(py) - (hy - r)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    }
}

/// One clean carrier opening. Coordinates are top-left pixels; stock geometry is in mm.
/// KS-1870: SMPTE ST 139:2003, Fig. 1/Table 1. E is an OUTER-edge gap, not a center inset.
/// The physical gate never adapts to an arbitrary photo ratio. Callers must crop first.
nonisolated struct FilmEdgeGeometry: Sendable {
    private(set) var width: Int, height: Int
    private(set) var gate: CGRect
    let format: FilmEdgeLayout.Format
    let portrait: Bool
    private(set) var millimetersPerPixel: Double
    let distress: FilmEdgeDistress
    struct CurvedHair: Sendable {
        let p0, p1, p2, p3, p4, p5, p6: SIMD2<Double>
        let minA, minT, maxA, maxT: Double
        let width, opacity, active: Double
    }
    struct HairBounds: Sendable { let minA, minT, maxA, maxT: Double }
    /// Seeded, resolution-independent features, computed once per geometry.
    let leakFrame: LeakFrame
    let scratchCandidates: [Scratch]
    let activeHairs: [CurvedHair]
    let hairUnionBounds: HairBounds
    /// Zoom-independent visible strip half-length (mm) used to anchor scan holder lint roots.
    let holderAlongHalf: Double
    /// Physical source-support half-extent around the gate center in rotated film mm (fx, fy).
    let supportHalf: (x: Double, y: Double)
    /// Normalized strip burn front depth in mm (negative means suppressed everywhere).
    let burnFrontDepth: Double
    /// Carrier opening half sizes in transport/across axes (mm); the canvas extends past them so
    /// the out-of-focus holder edge is visible.
    let carrierHalf: (along: Double, across: Double)
    /// Enlarger print on a hand-set easel: the opening's centre relative to the frame, canvas mm.
    let easelOffset: (x: Double, y: Double)
    /// Where the camera left the frame among its holes: not exactly centred on the eight, as the
    /// advance and the sprocket's play vary. Seeded, up to ±`maxRegistration` mm along the strip.
    let registration: Double
    static let maxRegistration = 0.3
    /// Creative routes: the material graph's scene stops at the inner edge of the penumbra, so a
    /// separately developed centre can fade straight into rebate without a rim of the material image.
    var erodesGate = false
    static let stockWidth = 34.975
    /// Veiling glare of a scan: fraction of light spread, and the spread's scale on the film.
    static let scanFlare = 0.035, scanFlareMicrometers = 220.0
    static let holeAcross = 2.794, holeAlong = 1.981, holeRadius = 0.51
    static let holePitch = 4.750, holeOuterGap = 2.01
    static let holeCenter = stockWidth / 2 - holeOuterGap - holeAcross / 2

    /// Kodak, *Essential Reference Guide for Filmmakers*, printed p. 96; SMPTE ST 93 / ST 139.
    /// KS-1870: still film and print film, rounded rectangle C 2.794 × D 1.981, R 0.51, pitch 4.750.
    /// BH-1866: cine camera negative, a C = 2.794 mm circle cut by flat edges D = 1.854 apart
    /// (sharp corners, calculated H 2.08), short pitch 4.740. C is the same, so the outer-edge gap
    /// E = 2.01 puts both hole centres at the same distance from the stock edge.
    enum Perforation: Int, Sendable {
        case ks1870 = 0, bh1866 = 1
        var pitch: Double { self == .ks1870 ? 4.750 : 4.740 }
        var halfAlong: Double { self == .ks1870 ? 1.981 / 2 : 1.854 / 2 }
        var halfAcross: Double { 2.794 / 2 }
        /// Motion-picture camera negatives keep BH holes when respooled for still cameras.
        static func source(filmID: String) -> Self { filmID.hasPrefix("kodak_vision3") ? .bh1866 : .ks1870 }
        /// Hole index, position relative to the nearest hole centre (`local` along, `t` across,
        /// signed away from the picture) and signed distance (> 0 in intact film).
        struct Hole { let index: Int32; let side: Int32; let local: Double; let t: Double; let distance: Double }
        func hole(along: Double, across: Double, holeCenter: Double = FilmEdgeGeometry.holeCenter) -> Hole {
            let k = floor(along / pitch)
            let local = along - (k + 0.5) * pitch
            let t = abs(across) - holeCenter
            return Hole(index: Int32(clamping: Int(k)), side: across < 0 ? -1 : 1, local: local, t: t,
                        distance: distance(local: local, t: t))
        }
        func distance(local: Double, t: Double) -> Double {
            switch self {
            case .ks1870:
                let r = FilmEdgeGeometry.holeRadius
                let qx = abs(local) - (halfAlong - r), qy = abs(t) - (halfAcross - r)
                return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
            case .bh1866:
                return max(abs(local) - halfAlong, hypot(local, t) - halfAcross)
            }
        }
        func isFilm(along: Double, across: Double) -> Bool { hole(along: along, across: across).distance >= 0 }
    }
    /// The source film's holes; a cinema print's own holes are always KS-1870.
    let perforation: Perforation
    /// Gate corner radius, from prints: a 35 mm camera gate is nearly square (about 0.1 mm,
    /// measured on Ilford Multigrade enlargements);
    /// a Hasselblad magazine's is nearly square, a moulded toy-camera mask very round.
    let gateCorner: Double
    /// Hasselblad V notches: centres along the left edge (mm from the frame centre), depth and
    /// half width of a blunt triangle, measured from two full-resolution frames (about 51 px/mm).
    /// Estimates, not factory drawings.
    let notched: Bool
    static let notchCentres = (-2.7, 2.4), notchDepth = 0.34, notchHalfWidth = 0.42, notchTip = 0.26
    static let rollStockWidth = 61.0
    static let scratchCount = 16

    /// What a transmission node does. Damage is source-film material; the carrier masks light
    /// where printing or scanning happens; the endpoint keeps clear openings black on paper.
    struct Transmission: OptionSet, Sendable {
        let rawValue: Int
        static let damage = Self(rawValue: 1)
        static let carrier = Self(rawValue: 2)
        static let endpoint = Self(rawValue: 4)
        static let destination = Self(rawValue: 8)
        /// Paper printing only: carrier-edge reflection of unmasked enlarger light.
        static let reflection = Self(rawValue: 16)
        /// Inverted negative scan: the holder's blocked light, inverted (`invertedHolder`).
        static let invertedHolder = Self(rawValue: 32)
    }

    /// `easel` supplies a hand-set enlarger print's placement; nil prints square and centred.
    init?(imageSize: CGSize, layout: FilmEdgeLayout, longEdge: Int, perforation: Perforation = .ks1870,
          easel: PrintLayout? = nil) {
        guard imageSize.width > 0, imageSize.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite,
              longEdge > 0, longEdge <= 65_536, layout.matchesGate(imageSize) else { return nil }
        isCleanPrint = false
        format = layout.format
        stockHalf = (layout.format == .film35 ? Self.stockWidth : Self.rollStockWidth) / 2
        holeCenterOffset = Self.holeCenter
        let roll = layout.format == .roll120
        gateCorner = !roll ? 0.1 : layout.rollGate == .toy ? 1.6 : 0.12
        notched = roll && layout.rollGate == .hasselblad
        self.perforation = perforation
        var resolved = Self.resolve(layout)
        // Set by eye, the projection lands a fraction of a degree off square and a little off
        // centre in the easel opening: the black rebate band tapers and differs side to side.
        let handSet = resolved.enlargerPrint && easel?.handSet == true
        let easelSeed = easel?.easelSeed ?? 1
        if handSet { resolved.tilt = min(max(resolved.tilt + 0.2 * Easel.jitter(easelSeed, 3), -3.3), 3.3) }
        // The blades' worn edge: the gate's wear profile at the easel's amplitude.
        if resolved.enlargerPrint { resolved.carrierRoughness = (easel?.blade ?? .natural).wear }
        distress = resolved
        easelOffset = handSet ? (0.12 * Easel.jitter(easelSeed, 4), 0.12 * Easel.jitter(easelSeed, 5)) : (0, 0)
        registration = Self.maxRegistration * (FilmEdgeNoise.unit(Self.streamSeed(resolved.seed, 61)) * 2 - 1)
        // `portrait` means the film runs vertically on the canvas. 6 × 4.5 frames lie across the
        // film, so a landscape 645 picture sits on a vertical strip.
        portrait = (imageSize.height > imageSize.width) == (layout.gateAlong >= layout.gateAcross)
        let nominalAlong = layout.nominalGateAlong
        let nominalAcross = layout.nominalGateAcross
        let actualAlong = layout.gateAlong
        let actualAcross = layout.gateAcross
        holderAlongHalf = nominalAlong * 0.66
        // Scan: the holder opening plus room for its out-of-focus edge; the canvas never changes.
        // Enlarger print: the easel opening (the nominal frame scaled by the print zoom) plus a
        // margin of the same sheet, wide enough for a hand-set offset and the blade's penumbra.
        let extent: CGSize
        if distress.enlargerPrint {
            carrierHalf = (nominalAlong / 2 / layout.printZoom, nominalAcross / 2 / layout.printZoom)
            let margin = FilmEdgeLayout.easelMargin * max(nominalAlong, nominalAcross)
            extent = CGSize(width: 2 * (carrierHalf.along + margin), height: 2 * (carrierHalf.across + margin))
        } else {
            // The scanner's crop window. A holder (negatives only) is open along the strip, where the
            // film continues past the frame gap, and masks across it, cutting through the holes on 35 mm.
            extent = CGSize(width: nominalAlong / layout.scanZoom, height: nominalAcross / layout.scanZoom)
            // Measured on P1485707 (318 px/mm): about 0.2 mm of each KS hole shows before the holder.
            let acrossReveal = format == .film35 ? 0.83 : 0.8
            carrierHalf = distress.scanHolder ? (1e4, nominalAcross / 2 + acrossReveal) : (1e4, 1e4)
        }
        let factor = Double(longEdge) / max(extent.width, extent.height)
        let landscapeSize = CGSize(width: max(1, (extent.width * factor).rounded()),
                                   height: max(1, (extent.height * factor).rounded()))
        width = Int(portrait ? landscapeSize.height : landscapeSize.width)
        height = Int(portrait ? landscapeSize.width : landscapeSize.height)
        // A single uniform pitch avoids stretching the holes when the canvas is rounded.
        millimetersPerPixel = 1 / factor
        let size = CGSize(width: (portrait ? actualAcross : actualAlong) * factor,
                          height: (portrait ? actualAlong : actualAcross) * factor)
        gate = CGRect(x: (Double(width) - size.width) / 2, y: (Double(height) - size.height) / 2,
                      width: size.width, height: size.height)
        let supportMargin = layout.apertureSupportMarginMm()
        supportHalf = (
            x: (portrait ? actualAcross : actualAlong) / 2 + (portrait ? supportMargin.across : supportMargin.along),
            y: (portrait ? actualAlong : actualAcross) / 2 + (portrait ? supportMargin.along : supportMargin.across)
        )
        let leakHalfAlong = nominalAlong / 2 + (format == .film35 ? 1.0 : 2.0)
        let leakHalfAcross = nominalAcross / 2 + (format == .film35 ? 1.35 : 2.0)
        leakFrame = Self.leakFrame(distress, portrait: portrait, halfAlong: leakHalfAlong, halfAcross: leakHalfAcross)
        let stripNormal = portrait ? (leakFrame.normal.1, -leakFrame.normal.0) : leakFrame.normal
        let alongEntry = abs(stripNormal.0) > 0.5
        let entryRebate = alongEntry ? (leakHalfAlong - actualAlong / 2) : (leakHalfAcross - actualAcross / 2)
        let pictureSpan = alongEntry ? actualAlong : actualAcross
        let cov = min(max(distress.burnCoverage, 0), 1)
        if cov <= 1e-6 {
            burnFrontDepth = -100.0
        } else {
            var depth = entryRebate + cov * pictureSpan
            if cov < 0.10 {
                let u = 1 - cov / 0.10
                depth -= 3.4 * u * u
            } else if cov > 0.90 {
                let u = (cov - 0.90) / 0.10
                depth += (entryRebate + 3.6) * u * u
            }
            burnFrontDepth = depth
        }
        let stripHalfAlong = nominalAlong / 2 + 2.0
        let rebateOuter = format == .film35 ? nominalAcross / 2 + 2.6 : nominalAcross / 2 + 2.4
        scratchCandidates = Self.scratches(
            distress, halfAlong: stripHalfAlong, halfAcross: rebateOuter, gateAcross: actualAcross / 2)
        let builtHairs = Self.curvedHairs(
            distress, halfAlong: nominalAlong / 2 + 1.8, halfAcross: nominalAcross / 2 + 2.0)
        activeHairs = builtHairs.hairs
        hairUnionBounds = builtHairs.union
    }

    /// Physical distress coordinates mapped onto any Clean-print aspect ratio (calibrated 36.54 mm
    /// 135 full-frame reference long edge), with edge fog, perforation fog, leaks, burn, dust, and
    /// scratches matching 135 Film Edge scale and position across every frame.
    init?(cleanPrintSize: CGSize, distress rawDistress: FilmEdgeDistress, longEdge: Int) {
        guard cleanPrintSize.width > 0, cleanPrintSize.height > 0,
              cleanPrintSize.width.isFinite, cleanPrintSize.height.isFinite,
              longEdge > 0, longEdge <= 65_536
        else { return nil }
        isCleanPrint = true
        format = .film35
        gateCorner = 0
        notched = false
        perforation = .ks1870
        portrait = cleanPrintSize.height > cleanPrintSize.width
        let aspect = Double(max(cleanPrintSize.width, cleanPrintSize.height) / min(cleanPrintSize.width, cleanPrintSize.height))
        let refScale = 1.015
        let actualAlong = 36.0 * refScale
        let actualAcross = actualAlong / max(aspect, 1.0)
        let refHalfAlong = 18.0 * refScale
        let refHalfAcross = 12.0 * refScale
        stockHalf = actualAcross / 2 + (Self.stockWidth / 2 - refHalfAcross)
        holeCenterOffset = actualAcross / 2 + (Self.holeCenter - refHalfAcross)
        var d = rawDistress.effective
        d.gateSoftness = 0
        d.gateWear = 0
        d.tilt = 0
        d.bulge = 0
        d.holeVariation = 0
        d.perforationLeak = min(1, 0.8 * d.edgeFog)
        d.scratchesInImage = rawDistress.scratchesInImage
        d.enlargerPrint = false
        d.scanHolder = false
        d.invertedScan = false
        d.carrierRoughness = 0
        d.carrierReflection = 0
        d.carrierDetail = 0
        d.fogDepth = 1.5 + 3 * d.edgeFog
        distress = d
        easelOffset = (0, 0)
        registration = 0
        holderAlongHalf = actualAlong * 0.66
        carrierHalf = (1e4, 1e4)
        let factor = Double(longEdge) / actualAlong
        let landscapeSize = CGSize(
            width: max(1, (actualAlong * factor).rounded()),
            height: max(1, (actualAcross * factor).rounded()))
        width = Int(portrait ? landscapeSize.height : landscapeSize.width)
        height = Int(portrait ? landscapeSize.width : landscapeSize.height)
        millimetersPerPixel = 1.0 / factor
        gate = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
        supportHalf = (
            x: Double(width) * millimetersPerPixel / 2,
            y: Double(height) * millimetersPerPixel / 2
        )
        let leakMarginAlong = 19.0 - refHalfAlong
        let leakMarginAcross = 13.35 - refHalfAcross
        let leakHalfAlong = actualAlong / 2 + leakMarginAlong
        let leakHalfAcross = actualAcross / 2 + leakMarginAcross
        leakFrame = Self.leakFrame(
            d, portrait: portrait, halfAlong: leakHalfAlong, halfAcross: leakHalfAcross)
        let stripNormal = portrait ? (leakFrame.normal.1, -leakFrame.normal.0) : leakFrame.normal
        let alongEntry = abs(stripNormal.0) > 0.5
        let entryRebate = alongEntry ? leakMarginAlong : leakMarginAcross
        let pictureSpan = alongEntry ? actualAlong : actualAcross
        let cov = min(max(d.burnCoverage, 0), 1)
        if cov <= 1e-6 {
            burnFrontDepth = -100.0
        } else {
            var depth = entryRebate + cov * pictureSpan
            if cov < 0.10 {
                let u = 1 - cov / 0.10
                depth -= 3.4 * u * u
            } else if cov > 0.90 {
                let u = (cov - 0.90) / 0.10
                depth += (entryRebate + 3.6) * u * u
            }
            burnFrontDepth = depth
        }
        scratchCandidates = Self.scratches(
            d, halfAlong: actualAlong / 2 + (20.0 - refHalfAlong),
            halfAcross: actualAcross / 2 + (14.6 - refHalfAcross),
            gateAcross: actualAcross / 2)
        let builtHairs = Self.curvedHairs(
            d, halfAlong: actualAlong / 2 + (19.8 - refHalfAlong),
            halfAcross: actualAcross / 2 + (14.0 - refHalfAcross))
        activeHairs = builtHairs.hairs
        hairUnionBounds = builtHairs.union
    }

    var pixelPitchMicrometers: Double { millimetersPerPixel * 1000 }
    var supportPixelSize: CGSize {
        CGSize(
            width: max(1, (2 * supportHalf.x / millimetersPerPixel).rounded()),
            height: max(1, (2 * supportHalf.y / millimetersPerPixel).rounded()))
    }
    /// The same strip, carrier and seeded features on a canvas `factor` times coarser: the
    /// low-resolution proxy of a region render. Everything else is defined in millimetres.
    func coarser(by factor: Int) -> FilmEdgeGeometry {
        var copy = self
        let f = Double(factor)
        copy.width = (width + factor - 1) / factor
        copy.height = (height + factor - 1) / factor
        copy.millimetersPerPixel = millimetersPerPixel * f
        copy.gate = CGRect(x: gate.minX / f, y: gate.minY / f, width: gate.width / f, height: gate.height / f)
        return copy
    }
    /// One resolved parameter set: handling distress (after Amount) plus the gate's optics. Gate
    /// tilt and bulge add to handling; the gate tilt's direction comes from the seed.
    static func resolve(_ layout: FilmEdgeLayout) -> FilmEdgeDistress {
        var d = layout.distress.effective
        let g = layout.gate
        let toy = layout.format == .roll120 && layout.rollGate == .toy
        d.gateSoftness = toy ? max(g.softness, 0.22) : g.softness
        d.gateWear = toy ? max(g.wear, 0.1) : g.wear
        if d.enlargerPrint {
            // Easel blades: straight, square-cornered and opaque, with no halo or reflection. Their
            // penumbra (`Easel`) for a nominal 6-inch print, in film mm; the radius is half the ramp.
            let m = 152.4 / max(layout.gateAlong, layout.gateAcross)
            d.carrierBlur = Easel.penumbra(magnification: m) / m / 2
            d.carrierDetail = 0; d.carrierTail = 0; d.carrierTailWidth = 0.1
            d.carrierCorner = 0.01; d.carrierWave = 0
            d.carrierRoughness = 0; d.carrierReflection = 0
        } else {
            // A scan holder is out of focus and scatters a short tail.
            d.carrierBlur = g.holderBlur
            d.carrierDetail = g.holderDetail
            d.carrierTail = 0.08
            d.carrierTailWidth = 0.12
            d.carrierCorner = 0.2
            d.carrierWave = 0.02
        }
        if d.revision < 5 {
            let sign: Double = streamSeed(d.seed, 60) & 1 == 0 ? 1 : -1
            d.tilt = min(max(g.tilt * sign + d.tilt, -3), 3)
            d.bulge = min(max(g.bulge + d.bulge, -1.5), 1.5)
        } else {
            d.tilt = min(max(d.tilt, -3), 3)
            d.bulge = min(max(d.bulge, -1.5), 1.5)
        }
        // Edge fog also pipes in through the perforations of the wrap above, and reaches deeper.
        d.perforationLeak = min(1, 0.8 * d.edgeFog)
        d.fogDepth = 1.5 + 3 * d.edgeFog
        return d
    }
    private var tiltRadians: Double { distress.tilt * .pi / 180 }
    let stockHalf: Double
    let isCleanPrint: Bool
    let holeCenterOffset: Double
    /// Canvas millimetres from the centre, in canvas x/y (y down).
    private func canvas(_ x: Double, _ y: Double) -> (Double, Double) {
        ((x - Double(width) / 2) * millimetersPerPixel, (y - Double(height) / 2) * millimetersPerPixel)
    }
    /// Film millimetres in canvas x/y: the strip turns by `tilt` inside the fixed carrier.
    func film(_ x: Double, _ y: Double) -> (Double, Double) {
        let (cx, cy) = canvas(x, y)
        let c = cos(tiltRadians), s = sin(tiltRadians)
        return (c * cx + s * cy, -s * cx + c * cy)
    }
    /// Transport (`along`) and stock-width (`across`) axes. Portrait is a rotation, not a mirror.
    private func strip(_ fx: Double, _ fy: Double) -> (along: Double, across: Double) {
        portrait ? (fy, -fx) : (fx, fy)
    }
    private var gateHalf: (Double, Double) { (gate.width * millimetersPerPixel / 2, gate.height * millimetersPerPixel / 2) }
    var pixelRadius: Double { 0.56 * millimetersPerPixel }
    private func seed(_ stream: UInt32) -> UInt32 { Self.streamSeed(distress.seed, stream) }

    /// Signed distance to the camera aperture in film strip coordinates (> 0 outside). Film that is
    /// not flat (bulge > 0) or dips (< 0) bows the outline along/across the strip: up to ~0.22 mm
    /// on the long film sides and ~0.15 mm on the short ends at full bulge, rotating cleanly with portrait.
    func gateDistance(_ fx: Double, _ fy: Double) -> Double {
        let (a, t) = strip(fx, fy)
        var ha = portrait ? gateHalf.1 : gateHalf.0
        var ht = portrait ? gateHalf.0 : gateHalf.1
        let ua = min(max(a / ha, -1), 1), ut = min(max(t / ht, -1), 1)
        let b = distress.bulge
        ha += 0.15 * b * (1 - ut * ut)
        ht += 0.22 * b * (1 - ua * ua)
        var d = FilmEdgeNoise.box(a, t, ha, ht, gateCorner)
        if notched {
            // Each notch is a small triangle of open gate pointing out of the left strip edge.
            let u = -(a + ha), slope = (Self.notchDepth * Self.notchDepth + Self.notchHalfWidth * Self.notchHalfWidth).squareRoot()
            for centre in [Self.notchCentres.0, Self.notchCentres.1] {
                let v = abs(t - centre)
                let side = (v * Self.notchDepth + u * Self.notchHalfWidth - Self.notchHalfWidth * Self.notchDepth) / slope
                d = min(d, max(side, max(-u - 0.3, u - Self.notchTip)))
            }
        }
        return d
    }
    /// Conservative strip-space inward/outward excursions (mm) beyond nominal `gateHalf` where
    /// `gateCoverage` can transition in (0, 1).
    func apertureExcursionMm() -> (inAlong: Double, inAcross: Double, outAlong: Double, outAcross: Double) {
        let r = hypot(distress.gateSoftness, pixelRadius)
        let wear = distress.gateWear
        let shift = erodesGate ? r + wear : 0
        let b = distress.bulge
        let inPad = 0.45 * gateCorner + r + wear + shift + 1e-3
        let outPad = r + wear + 1e-3
        return (
            inAlong: max(0, -0.15 * b) + inPad,
            inAcross: max(0, -0.22 * b) + inPad,
            outAlong: max(0, 0.15 * b) + (notched ? Self.notchDepth + 0.02 : 0) + outPad,
            outAcross: max(0, 0.22 * b) + outPad
        )
    }
    /// Camera-gate exposure coverage: penumbra, pixel area and seeded wear of the aperture edge.
    func gateCoverage(x: Int, y: Int) -> Double {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let base = gateDistance(fx, fy)
        let r = (distress.gateSoftness * distress.gateSoftness + pixelRadius * pixelRadius).squareRoot()
        let wear = distress.gateWear
        let shift = erodesGate ? r + wear : 0
        if base + shift < -(r + wear) { return 1 }
        if base + shift > r + wear { return 0 }
        var d = base
        if wear > 0 {
            let (a, t) = strip(fx, fy)
            d += wear * FilmEdgeNoise.wear(a, t, seed(1), seed(2))
        }
        return erodesGate ? FilmEdgeNoise.penumbra(d + shift, pixelRadius) : FilmEdgeNoise.penumbra(d, r)
    }

    /// Unwanted exposure, relative to a mid-grey scene exposure. `front` light comes through the
    /// lens and is gated with the scene; `back` (door/seal) light bypasses the gate; `fog` is
    /// base-path light: edge piping from the long film edges and perforation-shaped fog where
    /// light shone through the holes of the outer wrap onto the next one.
    struct Exposure: Sendable { var front = 0.0, back = 0.0, fog = 0.0, core = 0.0, burn = SIMD3<Double>.zero }
    func exposureFields(x: Int, y: Int) -> Exposure {
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        return exposureFields(filmX: fx, filmY: fy)
    }
    /// The same fields at a point in film millimetres (origin at the frame centre).
    func exposureFields(filmX fx: Double, filmY fy: Double, includeBurn: Bool = true) -> Exposure {
        let (a, t) = strip(fx, fy)
        var e = Exposure()
        if distress.edgeFog > 0 {
            let dPos = max(0, stockHalf - t)
            let dNeg = max(0, stockHalf + t)
            let fogLimit = 9.2 * distress.fogDepth
            if dPos < fogLimit || dNeg < fogLimit {
                let s = seed(3)
                let fogPos = dPos < fogLimit ? exp(-dPos / distress.fogDepth) * (0.6 + 0.4 * FilmEdgeNoise.value(a / 6, 3.5, s)) : 0
                let fogNeg = dNeg < fogLimit ? exp(-dNeg / distress.fogDepth) * (0.6 + 0.4 * FilmEdgeNoise.value(a / 6, -3.5, s)) : 0
                e.fog += 6 * distress.edgeFog * distress.edgeFog * (fogPos + fogNeg)
            }
        }
        if distress.perforationLeak > 0 && format == .film35 { e.fog += perforationFog(a, t) }
        if distress.holeVariation > 0 && format == .film35 && !isCleanPrint {
            let rim = holeRim(a, t)
            e.fog += rim.warm
            e.core += rim.core
        }
        if distress.leak > 0 {
            if distress.leakShape == .burn {
                if includeBurn { e.burn = burnLight(fx, fy) }
            } else {
                let value = 6 * distress.leak * distress.leak * leakField(fx, fy)
                if distress.leakKind == .front { e.front = value } else { e.back = value }
            }
        }
        return e
    }
    var burnPeak: Double { 160.0 * distress.leak * (0.35 + 0.65 * distress.leak) }
    func burnLightAt(filmX fx: Double, filmY fy: Double) -> SIMD3<Double> {
        guard distress.leakShape == .burn, distress.leak > 0, burnFrontDepth > -50 else { return .zero }
        return burnLight(fx, fy)
    }
    /// Roll-start burn calibrated against camera, Fuji Frontier and Noritsu scans: full-strip
    /// cassette-leader exposure with a signed-depth early-out, organic 2D velvet contour, and
    /// three-layer spectral saturation (white body -> golden-amber lip -> warm orange-red tail)
    /// anchored in physical strip coordinates across both picture gate and rebate.
    private func burnLight(_ fx: Double, _ fy: Double) -> SIMD3<Double> {
        let size = burnFrontDepth
        if size < -50 { return .zero }
        let leak = leakFrame, tex = distress.burnTexture
        let vx = fx - leak.point.0, vy = fy - leak.point.1
        let depth = vx * leak.normal.0 + vy * leak.normal.1
        let strength = distress.leak * (0.35 + 0.65 * distress.leak)
        let peak = 160.0 * strength
        if depth >= size + 3.4 { return .zero }
        if depth <= size - 3.6 { return SIMD3(repeating: peak) }
        let (a, t) = strip(fx, fy)
        let sn = portrait ? (leak.normal.1, -leak.normal.0) : leak.normal
        let axial = a * sn.0 + t * sn.1
        let u = a * sn.1 - t * sn.0
        let s = seed(4), pr = pixelRadius
        let wMed = 1 / (1 + (pr / 0.18) * (pr / 0.18))
        let wFine = 1 / (1 + (pr / 0.085) * (pr / 0.085))
        let bow = (0.22 + 0.42 * tex) * FilmEdgeNoise.value1D(u / 11.0, s)
            + (0.09 + 0.24 * tex) * FilmEdgeNoise.value1D(u / 3.6, s ^ 0x13579bdf)
        let clump = 0.5 + 0.5 * FilmEdgeNoise.value1D(u / 1.15, s ^ 0x2468ace1)
        let cloud = wMed * FilmEdgeNoise.value(axial / 1.10, u / 1.45, s ^ 0x55aa55aa)
        let wisp = wFine * FilmEdgeNoise.value(axial / 0.48, u / 0.42, s ^ 0x6c8e9cf5)
        let tuft = wMed * clump + 0.35 * cloud + 0.22 * tex * wisp
        let front = size + bow + (0.08 + 0.48 * tex) * (tuft - 0.5)
        let delta = depth - front
        let outRamp = min(max((size + 3.4 - depth) / 0.95, 0), 1)
        let window = outRamp * outRamp
        let inRamp = min(max((size - 2.65 - depth) / 0.95, 0), 1)
        let inBlend = inRamp * inRamp
        let w = min(max(distress.warmth, -1), 1)
        let warm = max(w, 0), cool = max(-w, 0)
        let plush = min(max(0.5 + 0.5 * cloud + 0.35 * (clump - 0.5), 0), 1)
        let plushReach = (0.40 + 0.60 * tex) * (0.45 + 0.55 * plush)
        let reachR = warm * (0.64 + 0.66 * plushReach)
        let reachG = (warm + cool) * (0.28 + 0.36 * plushReach)
        let reachB = cool * (0.64 + 0.66 * plushReach)
        let wR = hypot(0.13 + 0.16 * warm + 0.10 * tex, 1.25 * pr)
        let wG = hypot(0.13 + 0.08 * tex, 1.15 * pr)
        let wB = hypot(0.11 + 0.14 * cool + 0.08 * tex, 1.15 * pr)
        let denom = max(peak, 1e-9)
        let baseR = peak * FilmEdgeNoise.fastSigmoid((delta - reachR) / wR)
        let tailR = warm * (8.0 * strength) * (1 - baseR / denom)
            * FilmEdgeNoise.fastSigmoid((delta - reachR * 1.38) / (wR * 1.55))
        let cR = baseR + tailR
        let cG = peak * FilmEdgeNoise.fastSigmoid((delta - reachG) / wG)
        let baseB = peak * FilmEdgeNoise.fastSigmoid((delta - reachB) / wB)
        let tailB = cool * (8.0 * strength) * (1 - baseB / denom)
            * FilmEdgeNoise.fastSigmoid((delta - reachB * 1.38) / (wB * 1.55))
        let cB = baseB + tailB
        let raw = SIMD3(cR, cG, cB) * window
        return raw + (SIMD3(repeating: peak) - raw) * inBlend
    }
    private func leakField(_ fx: Double, _ fy: Double) -> Double {
        let leak = leakFrame, size = distress.leakSize
        let vx = fx - leak.point.0, vy = fy - leak.point.1
        let depth = max(0, vx * leak.normal.0 + vy * leak.normal.1)
        let lateral = vx * leak.normal.1 - vy * leak.normal.0
        let n = FilmEdgeNoise.value(fx / (0.6 * size), fy / (0.6 * size), seed(4))
        switch distress.leakShape {
        case .glow:
            let lobeA = exp(-lateral * lateral / (2 * pow(1.4 * size, 2)))
            let shifted = lateral - leak.offset * size
            let lobeB = exp(-shifted * shifted / (2 * pow(0.7 * size, 2)))
            return exp(-depth / size) * (lobeA + leak.weight * lobeB) * (0.75 + 0.25 * n)
        case .streak:
            let along = max(0, vx * leak.direction.0 + vy * leak.direction.1)
            let across = vx * leak.direction.1 - vy * leak.direction.0
            let core = exp(-across * across / (2 * pow(0.22 * size, 2)))
            let shifted = across - leak.offset * 0.9 * size
            let echo = leak.weight * 0.5 * exp(-shifted * shifted / (2 * pow(0.12 * size, 2)))
            return exp(-along / (3.5 * size)) * (core + echo) * (0.7 + 0.3 * n)
        case .burn:
            return burnLight(fx, fy).x / 6
        case .flare:
            let broad = exp(-lateral * lateral / (2 * pow(3 * size, 2)))
            let band = 0.8 + 0.2 * FilmEdgeNoise.value(lateral / (1.5 * size), 0.5, seed(4))
            return exp(-depth / (2.2 * size)) * broad * band
        }
    }
    /// Light piped in through the cut hole wall fogs a soft optical rim around each hole from
    /// the base side: C¹-continuous two-sided optical wall profile bandlimited to output pixel radius,
    /// without sub-pixel aliasing or harsh stair steps.
    private func holeRim(_ a: Double, _ t: Double) -> (warm: Double, core: Double) {
        let pr = pixelRadius
        let raw = perforation.hole(along: a + registration, across: t)
        let inWidth = hypot(0.028, 1.45 * pr)
        let coreWidth = hypot(0.044, 1.55 * pr)
        let haloWidth = hypot(0.095, 1.65 * pr)
        let peakPos = 0.012
        let maxIn = 5.3 * inWidth
        let maxOut = peakPos + 4.8 * haloWidth
        guard raw.distance > peakPos - maxIn - 0.03, raw.distance < maxOut + 0.03 else { return (0, 0) }
        let hole = jittered(raw, perforation)
        let s = hole.distance - peakPos
        guard s > -maxIn, s < 4.8 * haloWidth else { return (0, 0) }
        let v = distress.holeVariation
        let h = FilmEdgeNoise.hash(hole.index, hole.side, seed(47))
        let strength = 0.35 + 0.65 * FilmEdgeNoise.unit(h)
        let toward0 = min(max((-hole.t / perforation.halfAcross - 0.35) / 0.55, 0), 1)
        let toward = toward0 * toward0 * (3 - 2 * toward0)
        let side = 0.30 + 1.70 * toward
        let wStreak = 1 / (1 + (pr / 0.22) * (pr / 0.22))
        let mod = 0.68 + 0.32 * wStreak * FilmEdgeNoise.value1D(
            hole.local / 0.38 + Double(hole.index) * 3.1 + Double(hole.side) * 5.7, seed(48))
        let envCore: Double
        let envHalo: Double
        if s < 0 {
            let uc = -s / inWidth
            let uh = -s / (1.15 * inWidth)
            envCore = exp(-0.5 * uc * uc)
            envHalo = exp(-0.5 * uh * uh)
        } else {
            let uc = s / coreWidth
            let uh = s / haloWidth
            envCore = exp(-0.5 * uc * uc) / (1 + 0.35 * uc * uc)
            envHalo = exp(-0.5 * uh * uh) / (1 + 0.35 * uh * uh)
        }
        let halo = 2.4 * v * strength * side * mod * envHalo * (0.1272 / (1.15 * inWidth + haloWidth))
        let core = 5.2 * v * strength * toward * mod * envCore * (0.072 / (inWidth + coreWidth))
        return (halo, core)
    }
    /// The perforation-shaped part of edge fog alone, for checks.
    func perforationFogExposure(x: Int, y: Int) -> Double {
        guard distress.perforationLeak > 0, format == .film35 else { return 0 }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        return perforationFog(a, t)
    }
    func perforationFogAt(along a: Double, across t: Double) -> Double {
        guard distress.perforationLeak > 0, format == .film35 else { return 0 }
        return perforationFog(a, t)
    }
    /// The hole-wall rim alone (base-path halo, yellow core), for checks.
    func holeRimExposure(x: Int, y: Int) -> (warm: Double, core: Double) {
        guard distress.holeVariation > 0, format == .film35 else { return (0, 0) }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        return holeRim(a, t)
    }
    /// Light through a hole of the wrap above: a softened image of the hole, displaced toward the
    /// picture, on a seeded subset of holes. Very small exposures; through the base (warm).
    private func perforationFog(_ a: Double, _ t: Double) -> Double {
        if abs(t) < holeCenterOffset - 4.7 { return 0 }
        let p = perforation, side: Int32 = t < 0 ? -1 : 1
        let k0 = Int32(clamping: Int(floor(a / p.pitch)))
        let s = seed(41)
        var total = 0.0
        for dk in Int32(-1)...1 {
            let k = k0 &+ dk
            let h0 = FilmEdgeNoise.hash(k, side, s)
            let active = min(max((distress.perforationLeak * 0.85 - FilmEdgeNoise.unit(h0)) / 0.12, 0), 1)
            if active <= 0 { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2), h4 = FilmEdgeNoise.hash(h3)
            let centerA = (Double(k) + 0.5) * p.pitch + (FilmEdgeNoise.unit(h1) - 0.5) * 0.6 * p.pitch
            let inward = 0.3 + 1.2 * FilmEdgeNoise.unit(h2)
            let local = a - centerA, tt = abs(t) - (holeCenterOffset - inward)
            let soft = 0.12 + 0.35 * FilmEdgeNoise.unit(h3)
            // Sharp toward the light, softer away from it: widen the penumbra on the picture side.
            let r = soft * (tt < 0 ? 1.8 : 1)
            total += active * (0.4 + 0.6 * FilmEdgeNoise.unit(h4)) * FilmEdgeNoise.penumbra(p.distance(local: local, t: tt), r)
        }
        return 1.5 * distress.perforationLeak * distress.perforationLeak * total
    }

    struct LeakFrame: Sendable { let point: (Double, Double), normal: (Double, Double), offset: Double, weight: Double; let direction: (Double, Double) }
    /// The leak's entry point walks around the strip's perimeter; normal points into the film.
    static func leakFrame(_ d: FilmEdgeDistress, portrait: Bool, halfAlong ha: Double, halfAcross ht: Double) -> LeakFrame {
        let perimeter = 4 * (ha + ht)
        var s = (d.leakPosition - floor(d.leakPosition)) * perimeter
        var a = 0.0, t = 0.0, na = 0.0, nt = 0.0
        if s < 2 * ha { a = -ha + s; t = -ht; nt = 1 } else {
            s -= 2 * ha
            if s < 2 * ht { a = ha; t = -ht + s; na = -1 } else {
                s -= 2 * ht
                if s < 2 * ha { a = ha - s; t = ht; nt = -1 } else { s -= 2 * ha; a = -ha; t = ht - s; na = 1 }
            }
        }
        // Back to canvas x/y (inverse of `strip`).
        let point = portrait ? (-t, a) : (a, t)
        let normal = portrait ? (-nt, na) : (na, nt)
        let h = streamSeed(d.seed, 5), h2 = FilmEdgeNoise.hash(h), h3 = FilmEdgeNoise.hash(h2)
        // A streak leaves the entry edge up to ±35° from square to it.
        let turn = (FilmEdgeNoise.unit(h3) * 2 - 1) * 0.61
        let direction = (normal.0 * cos(turn) - normal.1 * sin(turn), normal.0 * sin(turn) + normal.1 * cos(turn))
        return LeakFrame(point: point, normal: normal, offset: FilmEdgeNoise.unit(h) * 1.6 - 0.8,
                         weight: 0.35 + 0.4 * FilmEdgeNoise.unit(h2), direction: direction)
    }
    static func streamSeed(_ seed: UInt32, _ stream: UInt32) -> UInt32 { FilmEdgeNoise.hash(seed ^ (stream &* 0x9e3779b9)) }

    /// Exact supersampled perforation coverage: 1 is intact film, 0 a clear opening.
    func supportCoverage(x: Int, y: Int, destination: Bool = false) -> Double {
        guard format == .film35, !isCleanPrint else { return 1 }
        let kind = destination ? Perforation.ks1870 : perforation
        let vary = !destination && distress.holeVariation > 0
        let sub = hypot(0.012, 0.22 * millimetersPerPixel)
        var covered = 0.0
        for sy in 0..<4 { for sx in 0..<4 {
            let (fx, fy) = film(Double(x) + (Double(sx) + 0.5) / 4, Double(y) + (Double(sy) + 0.5) / 4)
            let (along, across) = strip(fx, fy)
            // The source holes sit where the camera registered the frame; a print's own holes do not move.
            var hole = kind.hole(along: destination ? along : along + registration, across: across)
            if vary && abs(hole.distance) < 0.1 { hole = jittered(hole, kind) }
            if hole.distance >= sub { covered += 1 }
            else if hole.distance > -sub { covered += (hole.distance + sub) / (2 * sub) }
        }}
        return covered / 16
    }
    /// Punch tolerance: each hole sits and sizes a few microns differently, with a faint edge texture.
    func jittered(_ hole: Perforation.Hole, _ kind: Perforation) -> Perforation.Hole {
        let v = distress.holeVariation, s = seed(40)
        var h = FilmEdgeNoise.hash(hole.index, hole.side, s)
        func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) * 2 - 1 }
        let da = 0.012 * v * next(), dt = 0.01 * v * next(), grow = 0.008 * v * next()
        let local = hole.local - da, t = hole.t - dt
        let roughWeight = 1 / (1 + (pixelRadius / 0.045) * (pixelRadius / 0.045))
        let rough = 0.003 * v * roughWeight
            * FilmEdgeNoise.value(local / 0.045 + Double(hole.index) * 3.7, t / 0.045 + Double(hole.side) * 11.1, s)
        return Perforation.Hole(index: hole.index, side: hole.side, local: local, t: t,
                                distance: kind.distance(local: local, t: t) - grow + rough)
    }

    /// Signed distance to the carrier/holder opening (> 0 where it blocks light), fixed to the
    /// canvas: the film can tilt inside it.
    func carrierDistance(x: Int, y: Int) -> Double {
        let (px, py) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let cx = px - easelOffset.x, cy = py - easelOffset.y
        let (hx, hy) = portrait ? (carrierHalf.across, carrierHalf.along) : (carrierHalf.along, carrierHalf.across)
        let (a, t) = strip(cx, cy)
        let base = FilmEdgeNoise.box(cx, cy, hx, hy, distress.carrierCorner)
            + distress.carrierWave * FilmEdgeNoise.value(a / 11, t / 11, seed(52))
        let amplitude = distress.carrierRoughness
        guard amplitude > 0, base > -(amplitude * 1.6 + pixelRadius + distress.carrierBlur) else { return base }
        // Easel blades: the gate's wear profile, centred on the blade's line.
        if distress.enlargerPrint { return base + amplitude * FilmEdgeNoise.wear(a, t, seed(54), seed(55)) }
        let scale = distress.carrierScale
        // Mostly smooth filing with a little file-tooth texture and a few sparse nicks.
        let broad = 0.5 + 0.5 * (0.85 * FilmEdgeNoise.value(a / scale, t / scale, seed(6))
            + 0.15 * FilmEdgeNoise.value(a / (0.2 * scale), t / (0.2 * scale), seed(7)))
        let n = FilmEdgeNoise.value(a / (0.35 * scale), t / (0.35 * scale), seed(8))
        let notch = min(max((n - 0.6) / 0.3, 0), 1)
        return base + amplitude * (broad + 0.5 * notch * notch * (3 - 2 * notch))
    }
    /// Light passed by the holder: a crisp core (its defocus) plus a faint wide tail of scattered
    /// light, and specks of light through an abraded edge. On an inverted negative the faint tail
    /// prints as a visible band; on a slide it disappears into black, as in real scans.
    func carrierCoverage(x: Int, y: Int) -> Double {
        let d = carrierDistance(x: x, y: y)
        let r = max(distress.carrierBlur, pixelRadius)
        // An enlarger carrier is opaque; its scattered light carries no image (see `carrierHalo`).
        if distress.enlargerPrint { return d < -r ? 1 : FilmEdgeNoise.penumbra(d, r) }
        let detail = distress.carrierDetail
        let hasHolderFibres = detail > 0 && !(carrierHalf.along > 1e3 && carrierHalf.across > 1e3)
        if !hasHolderFibres {
            if d < -r { return 1 }
        } else if d < -2.4 {
            return 1
        }
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        if d < -r {
            return 1 - holderFibres(cx, cy)
        }
        let open = FilmEdgeNoise.penumbra(d, r)
        var pass = open + (1 - open) * distress.carrierTail * exp(-max(d, 0) / distress.carrierTailWidth)
        guard detail > 0 else { return pass }
        if hasHolderFibres && d > -2.4 { pass *= 1 - holderFibres(cx, cy) }
        guard d < r + 0.45 else { return pass }
        let (a, t) = strip(cx, cy)
        // Organic abrasion: two octaves, a soft threshold, patchy along the edge, densest at it.
        let n = 0.6 * FilmEdgeNoise.value(a / 0.05, t / 0.05, seed(49)) + 0.4 * FilmEdgeNoise.value(a / 0.15, t / 0.15, seed(51))
        let u = min(max((n - 0.15) / 0.55, 0), 1)
        let patch = 0.5 + 0.5 * FilmEdgeNoise.value(a / 0.6, t / 0.6, seed(50))
        let speck = u * u * (3 - 2 * u) * patch * patch
        pass += (1 - pass) * detail * 0.5 * speck * exp(-max(d - r * 0.5, 0) / 0.12)
        return pass
    }
    /// Lint caught on the holder edge, in silhouette: a few hairs reach into the opening, rooted
    /// under the holder and as far out of focus as its edge. Canvas millimetres.
    static let fibreCount = 6
    func holderFibres(_ cx: Double, _ cy: Double) -> Double {
        let detail = distress.carrierDetail
        guard detail > 0 else { return 0 }
        let alongUnlimited = carrierHalf.along > 1e3
        let acrossUnlimited = carrierHalf.across > 1e3
        if alongUnlimited && acrossUnlimited { return 0 }
        let (hx, hy) = portrait ? (carrierHalf.across, carrierHalf.along) : (carrierHalf.along, carrierHalf.across)
        let blur = max(pixelRadius, 0.5 * distress.carrierBlur)
        var clear = 1.0
        for k in 0..<Self.fibreCount {
            let h0 = FilmEdgeNoise.hash(Int32(k), 0, seed(53))
            guard FilmEdgeNoise.unit(h0) < 0.15 + 0.85 * detail else { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2)
            let h4 = FilmEdgeNoise.hash(h3), h5 = FilmEdgeNoise.hash(h4), h6 = FilmEdgeNoise.hash(h5)
            let u = FilmEdgeNoise.unit(h2) * 2 - 1
            var px = 0.0, py = 0.0, nx = 0.0, ny = 0.0
            if alongUnlimited {
                let a = u * holderAlongHalf
                let ht = carrierHalf.across
                let side = h1 & 1
                let t = side == 0 ? -ht : ht
                let nt = side == 0 ? 1.0 : -1.0
                if portrait { px = -t; py = a; nx = -nt; ny = 0 }
                else { px = a; py = t; nx = 0; ny = nt }
            } else {
                switch h1 & 3 {
                case 0: px = u * hx; py = -hy; ny = 1
                case 1: px = u * hx; py = hy; ny = -1
                case 2: px = -hx; py = u * hy; nx = 1
                default: px = hx; py = u * hy; nx = -1
                }
            }
            let size = FilmEdgeNoise.unit(h3), length = 0.3 + 1.8 * size * size
            let angle = (FilmEdgeNoise.unit(h4) - 0.5) * 2, curl = (FilmEdgeNoise.unit(h5) - 0.5) * 1.6
            let c = cos(angle), s = sin(angle)
            let dx = c * nx - s * ny, dy = s * nx + c * ny
            px -= 0.15 * nx; py -= 0.15 * ny
            // Conservative AABB reject accommodating curved strands and defocus blur.
            let reach = 1.32 * length + 3 * blur + 0.05
            guard abs(cx - px) < reach, abs(cy - py) < reach else { continue }
            var nearest = Double.infinity
            var ax = px, ay = py
            for i in 1...8 {
                let q = Double(i) / 8
                let bx = px + (dx * q - dy * curl * q * q) * length
                let by = py + (dy * q + dx * curl * q * q) * length
                let ex = bx - ax, ey = by - ay
                let w = min(max(((cx - ax) * ex + (cy - ay) * ey) / max(ex * ex + ey * ey, 1e-12), 0), 1)
                nearest = min(nearest, hypot(cx - ax - w * ex, cy - ay - w * ey))
                ax = bx; ay = by
            }
            let width = 0.008 + 0.012 * FilmEdgeNoise.unit(h6), rr = max(width, 0.9 * blur)
            clear *= 1 - 0.85 * (width / rr) * FilmEdgeNoise.penumbra(nearest - rr, blur)
        }
        return 1 - clear
    }
    /// Light scattered by a filed carrier's bare edge falls on the paper just outside the
    /// opening: an imageless glow that fades the black border into the white margin.
    func carrierHalo(x: Int, y: Int) -> Double {
        guard distress.enlargerPrint else { return 0 }
        let d = carrierDistance(x: x, y: y)
        let r = max(distress.carrierBlur, pixelRadius)
        guard d > -r else { return 0 }
        return (1 - FilmEdgeNoise.penumbra(d, r)) * distress.carrierTail * exp(-max(d, 0) / distress.carrierTailWidth)
    }
    /// Enlarger light glancing off a bare-metal carrier edge lands just inside the opening without
    /// passing through the negative's mask, so on RA-4 it prints as a darker, coloured band.
    func carrierReflection(x: Int, y: Int) -> Double {
        let r = distress.carrierReflection
        guard r > 0 else { return 0 }
        let d = carrierDistance(x: x, y: y)
        guard d < 0 else { return 0 }
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(cx, cy)
        let n = FilmEdgeNoise.value(a / 4, t / 4, seed(43))
        return 0.4 * r * exp(d / 0.45) * (0.7 + 0.3 * n)
    }

    /// Precomputed rare fine curved hairs anchored in zoom-independent strip coordinates (mm).
    static func curvedHairs(_ d: FilmEdgeDistress, halfAlong ha: Double, halfAcross ht: Double)
        -> (hairs: [CurvedHair], union: HairBounds)
    {
        guard d.dust > 0 else { return ([], HairBounds(minA: 0, minT: 0, maxA: -1, maxT: -1)) }
        var hairs: [CurvedHair] = []
        var uMinA = Double.infinity, uMinT = Double.infinity
        var uMaxA = -Double.infinity, uMaxT = -Double.infinity
        let rareCuts = (0.78, 0.56, 0.42)
        let thresholds = (0.16, 0.44, 0.72)
        for k in 0..<3 {
            var h = streamSeed(d.seed, 14 + UInt32(k))
            func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
            let rareCut = k == 0 ? rareCuts.0 : (k == 1 ? rareCuts.1 : rareCuts.2)
            let threshold = k == 0 ? thresholds.0 : (k == 1 ? thresholds.1 : thresholds.2)
            guard next() < rareCut else { continue }
            let active = min(max((d.dust - threshold) / 0.08, 0), 1)
            let a0 = (next() * 2 - 1) * ha * 0.86
            let t0 = (next() * 2 - 1) * ht * 0.86
            let totalLen = 1.6 + 2.8 * next(), stepLen = totalLen / 6.0
            let theta0 = next() * 6.2831853
            let c1 = (next() * 2 - 1) * 1.7, c2 = (next() * 2 - 1) * 2.1, cHook = (next() * 2 - 1) * 3.0
            let width = 0.0055 + 0.0055 * next(), opacity = 0.66 + 0.28 * next()
            guard active > 0 else { continue }
            var pts: [SIMD2<Double>] = [SIMD2(a0, t0)]
            var a = a0, t = t0
            var minA = a0, minT = t0, maxA = a0, maxT = t0
            for m in 1...6 {
                let q = Double(m) / 6.0
                let hook = max(0.0, q - 0.62) / 0.38
                let angle = theta0 + c1 * q + c2 * q * q + cHook * hook * hook
                a += stepLen * cos(angle)
                t += stepLen * sin(angle)
                pts.append(SIMD2(a, t))
                minA = min(minA, a); minT = min(minT, t)
                maxA = max(maxA, a); maxT = max(maxT, t)
            }
            let hair = CurvedHair(
                p0: pts[0], p1: pts[1], p2: pts[2], p3: pts[3], p4: pts[4], p5: pts[5], p6: pts[6],
                minA: minA, minT: minT, maxA: maxA, maxT: maxT,
                width: width, opacity: opacity, active: active)
            hairs.append(hair)
            uMinA = min(uMinA, minA); uMinT = min(uMinT, minT)
            uMaxA = max(uMaxA, maxA); uMaxT = max(uMaxT, maxT)
        }
        let union = hairs.isEmpty ? HairBounds(minA: 0, minT: 0, maxA: -1, maxT: -1)
            : HairBounds(minA: uMinA, minT: uMinT, maxA: uMaxA, maxT: uMaxT)
        return (hairs, union)
    }

    private static func hairSegmentDistance(
        _ a: Double, _ t: Double, _ p0: SIMD2<Double>, _ p1: SIMD2<Double>
    ) -> (dist: Double, w: Double) {
        let ex = p1.x - p0.x, ey = p1.y - p0.y
        let w = min(max(((a - p0.x) * ex + (t - p0.y) * ey) / max(ex * ex + ey * ey, 1e-12), 0), 1)
        return (hypot(a - p0.x - w * ex, t - p0.y - w * ey), w)
    }

    /// Opaque particles on the developed film: asymmetric flecks, bent lint and rare curved hairs, in film millimetres.
    func dustOcclusion(x: Int, y: Int) -> Double {
        let density = distress.dust
        guard density > 0 else { return 0 }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        let cell = 1.6, pr = pixelRadius
        let ci = Int32(floor(a / cell)), cj = Int32(floor(t / cell))
        var clear = 1.0
        let s = seed(9)
        for dj in Int32(-1)...1 { for di in Int32(-1)...1 {
            let i = ci &+ di, j = cj &+ dj
            let h0 = FilmEdgeNoise.hash(i, j, s)
            let activation = min(max((density * 0.45 - FilmEdgeNoise.unit(h0)) / 0.04, 0), 1)
            if activation <= 0 { continue }
            let h1 = FilmEdgeNoise.hash(h0), h2 = FilmEdgeNoise.hash(h1), h3 = FilmEdgeNoise.hash(h2)
            let h4 = FilmEdgeNoise.hash(h3)
            let pa = (Double(i) + FilmEdgeNoise.unit(h1)) * cell - a
            let pt = (Double(j) + FilmEdgeNoise.unit(h2)) * cell - t
            let kind = FilmEdgeNoise.unit(h3), size = FilmEdgeNoise.unit(h4)
            let h5 = FilmEdgeNoise.hash(h4), h6 = FilmEdgeNoise.hash(h5)
            let h7 = FilmEdgeNoise.hash(h6), h8 = FilmEdgeNoise.hash(h7)
            let h9 = FilmEdgeNoise.hash(h8)
            let u5 = FilmEdgeNoise.unit(h5), u6 = FilmEdgeNoise.unit(h6)
            let u7 = FilmEdgeNoise.unit(h7), u8 = FilmEdgeNoise.unit(h8), u9 = FilmEdgeNoise.unit(h9)
            let cover: Double
            if kind < 0.78 {
                let rho = 0.008 + 0.046 * size * size
                let rr = max(rho, pr * 0.88)
                let soft = pr * (0.72 + 0.16 * u5)
                let reach = 1.75 * rr + 1.3 * soft + 1e-4
                if abs(pa) > reach || abs(pt) > reach { continue }
                let h10 = FilmEdgeNoise.hash(h9)
                let u10 = FilmEdgeNoise.unit(h10)
                let res = rho / rr
                let opacity = 0.64 + 0.34 * (0.35 * u6 + 0.65 * size)
                let theta = u7 * 6.2831853
                let c = cos(theta), sn = sin(theta)
                let qx = pa * c + pt * sn, qy = -pa * sn + pt * c
                let sA = 1.0 + 0.24 * u8 * res
                let dBody = hypot(qx / sA, qy * sA) - rr
                let ox = rr * (0.42 + 0.46 * u9) * res, oy = rr * 0.26 * (u10 * 2 - 1) * res
                let rr2 = rr * (0.48 + 0.30 * u5)
                let dLobe = hypot(qx - ox, qy - oy) - rr2
                let dMin = min(dBody, dLobe)
                cover = res * res * FilmEdgeNoise.penumbra(dMin, soft) * opacity
            } else {
                let len = 0.11 + 0.50 * size * size
                let reach = len + 2.2 * pr + 0.02
                if abs(pa) > reach || abs(pt) > reach { continue }
                let rho0 = 0.0045 + 0.0075 * u5
                let opacity = 0.68 + 0.30 * u6
                let split = 0.54 + 0.24 * u7
                let angle1 = kind * 25.132741
                let bend = (u8 < 0.5 ? -1.0 : 1.0) * (0.50 + 0.92 * u9)
                let angle2 = angle1 + bend
                let u1x = cos(angle1), u1y = sin(angle1)
                let u2x = cos(angle2), u2y = sin(angle2)
                let arm1 = split * len, arm2 = (1 - split) * len
                let p0x = -0.5 * arm1 * u1x, p0y = -0.5 * arm1 * u1y
                let p1x = 0.5 * arm1 * u1x, p1y = 0.5 * arm1 * u1y
                let p2x = p1x + arm2 * u2x, p2y = p1y + arm2 * u2y
                let qx = -pa, qy = -pt
                let e1x = p1x - p0x, e1y = p1y - p0y
                let w1 = min(max(((qx - p0x) * e1x + (qy - p0y) * e1y) / max(e1x * e1x + e1y * e1y, 1e-12), 0), 1)
                let d1 = hypot(qx - p0x - w1 * e1x, qy - p0y - w1 * e1y)
                let e2x = p2x - p1x, e2y = p2y - p1y
                let w2 = min(max(((qx - p1x) * e2x + (qy - p1y) * e2y) / max(e2x * e2x + e2y * e2y, 1e-12), 0), 1)
                let d2 = hypot(qx - p1x - w2 * e2x, qy - p1y - w2 * e2y)
                let dist = min(d1, d2)
                let tArc = d1 <= d2 ? split * w1 : split + (1 - split) * w2
                let taper = max(0.30, 1.0 - 0.65 * (2 * tArc - 1) * (2 * tArc - 1))
                let rho = rho0 * taper, rr = max(rho, pr * 0.95)
                cover = (rho / rr) * FilmEdgeNoise.penumbra(dist - rr, pr * 0.90) * opacity
            }
            clear *= 1 - cover * activation
        }}
        if !activeHairs.isEmpty {
            let pad = 0.02 + 2.2 * pr
            if a >= hairUnionBounds.minA - pad && a <= hairUnionBounds.maxA + pad
                && t >= hairUnionBounds.minT - pad && t <= hairUnionBounds.maxT + pad
            {
                for hair in activeHairs {
                    let hPad = hair.width + 2.2 * pr + 1e-4
                    guard a >= hair.minA - hPad && a <= hair.maxA + hPad
                        && t >= hair.minT - hPad && t <= hair.maxT + hPad
                    else { continue }
                    let segs = (
                        Self.hairSegmentDistance(a, t, hair.p0, hair.p1),
                        Self.hairSegmentDistance(a, t, hair.p1, hair.p2),
                        Self.hairSegmentDistance(a, t, hair.p2, hair.p3),
                        Self.hairSegmentDistance(a, t, hair.p3, hair.p4),
                        Self.hairSegmentDistance(a, t, hair.p4, hair.p5),
                        Self.hairSegmentDistance(a, t, hair.p5, hair.p6)
                    )
                    var bestDist = segs.0.dist
                    var bestQ = segs.0.w / 6.0
                    let arr = [segs.1, segs.2, segs.3, segs.4, segs.5]
                    for (idx, seg) in arr.enumerated() where seg.dist < bestDist {
                        bestDist = seg.dist
                        bestQ = (Double(idx + 1) + seg.w) / 6.0
                    }
                    if bestDist <= hair.width + 2.2 * pr {
                        let norm = bestQ * 2 - 1
                        let norm2 = norm * norm
                        let taper = max(0.22, 1.0 - 0.78 * norm2 * norm2)
                        let rho = hair.width * taper, rr = max(rho, pr * 0.95)
                        let cover = (rho / rr) * FilmEdgeNoise.penumbra(bestDist - rr, pr * 0.90) * hair.opacity * hair.active
                        clear *= 1 - cover
                    }
                }
            }
        }
        return 1 - clear
    }

    /// Seeded scratch candidates; Strength activates them in order so none jumps.
    /// `depth` > 0 is an emulsion scratch cutting that fraction of the dye stack from the top;
    /// `depth` < 0 is a scatter scratch (base side or a light scuff) of strength |depth|.
    /// Like real rail and sprocket wear they are long, thin, near-parallel and clustered in a few
    /// bands, mostly faint with an occasional strong one, and often broken into dashes.
    struct Scratch: Sendable { let across, slope, wander, wavelength, phase, start, end, width, depth, dash, bias: Double }
    static func scratches(_ d: FilmEdgeDistress, halfAlong ha: Double, halfAcross ht: Double, gateAcross: Double) -> [Scratch] {
        var b = streamSeed(d.seed, 19)
        func band() -> Double { b = FilmEdgeNoise.hash(b); return FilmEdgeNoise.unit(b) }
        let inner = gateAcross + 0.04, outer = max(inner + 0.05, ht)
        let railSpan = min(0.44, outer - inner)
        let bands = (0..<4).map { index in
            index < 3 ? inner + railSpan * band() : inner + (outer - inner) * band()
        }
        let imageLimit = gateAcross * 0.92
        return (0..<scratchCount).map { k in
            var h = streamSeed(d.seed, UInt32(20 + k))
            func next() -> Double { h = FilmEdgeNoise.hash(h); return FilmEdgeNoise.unit(h) }
            let side: Double = next() < 0.5 ? -1 : 1
            let bandPick = next()
            let center = k < 3 ? bands[Int(bandPick * 2.999)] : bands[Int(bandPick * 3.999)]
            let maxAcross = k < 3 ? min(outer, inner + railSpan + 0.06) : outer
            let clustered = min(max(center + (next() * 2 - 1) * 0.08, inner), maxAcross)
            // Draw both positions every time so toggling the clamp never shifts other features.
            let free = next(), anywhere = (next() * 2 - 1) * imageLimit
            let across = d.scratchesInImage && free < 0.6 ? anywhere : side * clustered
            let slope = (next() * 2 - 1) * 0.0008
            let wander = 0.001 + 0.007 * next(), wavelength = 60 + 140 * next(), phase = next() * 6.2832
            let span = ha * ((k < 2 ? 0.85 : 0.55) + 1.55 * next())
            let mid = (next() * 2 - 1) * ha * (k < 2 ? 0.65 : 1.0)
            let width = (k < 2 ? 0.011 : 0.006) + 0.017 * pow(next(), 1.15)
            let emulsionRoll = next()
            let emulsion = k == 1 ? false : emulsionRoll < 0.28
            let depthRoll = next()
            let depth = emulsion
                ? 0.10 + 0.78 * pow(depthRoll, 1.6)
                : -((k < 2 ? 0.72 : 0.58) + (k < 2 ? 0.24 : 0.38) * pow(depthRoll, 0.85))
            let dash = 1.8 + 8.0 * next(), bias = (k < 2 ? 0.28 : 0.16) + 0.64 * next()
            return Scratch(across: across, slope: slope, wander: wander, wavelength: wavelength, phase: phase,
                           start: mid - span, end: mid + span, width: width, depth: depth, dash: dash, bias: bias)
        }
    }
    /// Dye removed by emulsion scratches, top layer first. Colour film (still, cine and reversal)
    /// is coated blue-sensitive/yellow on top, then green/magenta, then red/cyan nearest the base;
    /// density channels are (cyan, magenta, yellow). The print or scan then decides the colour:
    /// a shallow cut prints yellow from a negative, looks blue on a slide or the negative itself.
    struct ScratchFields: Sendable { var removal = SIMD3<Double>.zero; var scatter = 0.0 }
    static func effectiveScratchAmount(_ scratches: Double) -> Double {
        let s = min(max(scratches, 0), 1)
        let u = max(0, s - 0.15) / 0.85
        return s - 0.30 * u * u
    }
    func scratchFields(x: Int, y: Int) -> ScratchFields {
        var result = ScratchFields()
        let amount = Self.effectiveScratchAmount(distress.scratches)
        guard amount > 0 else { return result }
        let (fx, fy) = film(Double(x) + 0.5, Double(y) + 0.5)
        let (a, t) = strip(fx, fy)
        let pr = pixelRadius
        var outside = 1.0
        if !distress.scratchesInImage {
            if isCleanPrint { return result }
            outside = 1 - FilmEdgeNoise.penumbra(gateDistance(fx, fy), pr)
            if outside <= 0 { return result }
        }
        for (k, s) in scratchCandidates.enumerated() {
            let active = min(max(amount * Double(Self.scratchCount) - Double(k), 0), 1)
            if active <= 0 { continue }
            let ends = min(max((a - s.start) / 2, 0), 1) * min(max((s.end - a) / 2, 0), 1)
            if ends <= 0 { continue }
            let line = s.across + s.slope * a + s.wander * sin(a / s.wavelength * 6.2832 + s.phase)
            let rr = max(s.width, pr * 0.85)
            if abs(t - line) > rr + pr { continue }
            // Pressure varies along the run: the scratch breaks up and fades rather than drawing a ruler line.
            let pressure = FilmEdgeNoise.value(a / s.dash, Double(k) * 7.31, seed(30))
            let broken = min(max((pressure + s.bias) / 0.35, 0), 1)
            let cover = (s.width / rr).squareRoot() * FilmEdgeNoise.penumbra(abs(t - line) - rr, pr) * ends * active * broken * outside
            if s.depth > 0 {
                let d = s.depth * 3
                let r = SIMD3(min(max(d - 2, 0), 1), min(max(d - 1, 0), 1), min(max(d, 0), 1)) * cover
                result.removal = SIMD3(max(result.removal.x, r.x), max(result.removal.y, r.y), max(result.removal.z, r.z))
            } else {
                result.scatter = max(result.scatter, -s.depth * cover)
            }
        }
        return result
    }
    /// Geometric/Mie forward-cone scatter from 6–25 µm base scratches removes light across all three
    /// bands with a mild short-wavelength bias, lifting RA-4 paper exposure out of D-max black.
    static let scatterWeights = SIMD3<Double>(0.62, 0.78, 1.0)
    var hasEmulsionScratches: Bool { distress.scratches > 0 && scratchCandidates.contains { $0.depth > 0 } }

    /// Combine intact film and clear light in transmission; never average densities with air.
    func transmit(_ film: SIMD3<Double>, clear: SIMD3<Double>, x: Int, y: Int, mode: Transmission) -> SIMD3<Double> {
        if mode.contains(.invertedHolder) { return invertedHolder(film, x: x, y: y) }
        let support = supportCoverage(x: x, y: y, destination: mode.contains(.destination))
        let carrier = mode.contains(.carrier) ? carrierCoverage(x: x, y: y) : 1
        // Clear openings are the black reference wherever the carrier passes light.
        if mode.contains(.endpoint) { return film * (1 - carrier * (1 - support)) }
        var occlusion = SIMD3<Double>.zero
        if mode.contains(.damage) {
            let dust = dustOcclusion(x: x, y: y), scatter = scratchFields(x: x, y: y).scatter
            occlusion = 1 - (1 - dust) * (1 - scatter * Self.scatterWeights)
        }
        var light = (film * support + clear * (1 - support)) * (1 - occlusion * support) * carrier
        if mode.contains(.reflection) { light += clear * (carrierReflection(x: x, y: y) * carrier + carrierHalo(x: x, y: y)) }
        return light
    }
    /// The holder in an inverted negative scan (matched to a camera scan, P1485707, at 318 px/mm).
    /// Where it passes a fraction c of the light the raw capture is c times darker, down to a flare
    /// floor that is the same over any film; inversion turns the capture into brightness:
    /// v = 1 / (c^γ / q + (1 − c) / (1.1 W)), q the film's own inverted value. Over a clear hole
    /// that runs black → red → orange → yellow, over the rebate salmon pink, and under the solid
    /// holder both reach the same slightly over-white value that the scan's white point W clips
    /// per channel (pinkish). The holder is nearly in focus (≈ 0.1 mm ramp) with the gate's wear
    /// profile on its cut edge. Capture noise, amplified by inversion, is strongest where the edge
    /// is soft and mild in the solid white: blotches streaked along the edge. Light scattered off
    /// the edge adds raw exposure just inside the opening (a darker band). Linear output.
    static let holderGamma = SIMD3<Double>(1.4, 1.0, 0.75)
    static let holderWhite = SIMD3<Double>(1.0, 0.82, 0.78)
    /// The inverted scan's black offset: clear film inverts to a little above zero.
    static let holderBlack = 0.012, holderWear = 0.02
    static let holderScatter = 0.55, holderScatterWidth = 0.07
    func invertedHolder(_ film: SIMD3<Double>, x: Int, y: Int) -> SIMD3<Double> {
        let r = max(distress.carrierBlur, pixelRadius)
        var d = carrierDistance(x: x, y: y)
        let innerLimit = r + Self.holderWear + 6 * Self.holderScatterWidth
        let hasHolderFibres = distress.carrierDetail > 0 && !(carrierHalf.along > 1e3 && carrierHalf.across > 1e3)
        if !hasHolderFibres {
            guard d > -innerLimit else { return film }
        } else if d <= -2.4 {
            return film
        }
        let (cx, cy) = canvas(Double(x) + 0.5, Double(y) + 0.5)
        let fibre = hasHolderFibres ? holderFibres(cx, cy) : 0
        if d <= -innerLimit && fibre <= 0 { return film }
        let (a, t) = strip(cx, cy)
        d += Self.holderWear * FilmEdgeNoise.wear(a, t, seed(62), seed(63))
        let c = FilmEdgeNoise.penumbra(d, r) * (1 - fibre)
        // Blotches streaked 3:1 along the edge, never finer than ~1.5 output pixels; coarser
        // sampling averages them, so their strength falls with the same factor.
        let fine = max(0.015, 2.7 * pixelRadius), coarse = max(0.045, 5.4 * pixelRadius)
        let luma = 0.6 * FilmEdgeNoise.value(a / (3 * fine), t / fine, seed(56))
            + 0.4 * FilmEdgeNoise.value(a / (3 * coarse), t / coarse, seed(57))
        let sigma = (0.7 * (1 - c) * min(1, c / 0.15) + 0.08) * (0.015 / fine).squareRoot()
        // Scattered light inside the opening darkens the inverted rebate.
        let scatter = d < 0 ? 1 - Self.holderScatter * exp(d / Self.holderScatterWidth) : 1
        var out = SIMD3<Double>.zero
        for i in 0..<3 {
            let chroma = FilmEdgeNoise.value(a / (3 * coarse), t / coarse, seed(58 + UInt32(i)))
            // Sharpening rings slightly below zero beside edges; a raw capture cannot.
            let q = max(film[i], 0) * scatter + Self.holderBlack
            let v = 1 / (pow(c, Self.holderGamma[i]) / q + (1 - c) / (1.1 * Self.holderWhite[i]))
            let noisy = v * pow(10, (0.95 * luma + 0.05 * chroma) * sigma * (1 - c))
            out[i] = min(max(noisy - Self.holderBlack, 0), Self.holderWhite[i])
        }
        return out
    }
    /// Emulsion scratches thin the developed dye before printing or scanning.
    func scratchedDensity(_ density: SIMD3<Double>, x: Int, y: Int) -> SIMD3<Double> {
        density * (1 - scratchFields(x: x, y: y).removal)
    }

    /// Matches the Metal edge kernels. No full-frame mask bitmap is allocated.
    func uniforms(light: SIMD3<Double> = .zero, fogLight: SIMD3<Double> = .zero,
                  coreLight: SIMD3<Double> = .zero, neutral: SIMD3<Double> = .zero) -> [SIMD4<Float>] {
        let d = distress
        let (gx, gy) = gateHalf
        let leak = leakFrame
        var values: [SIMD4<Float>] = [
            SIMD4(Float(width), Float(height), Float(millimetersPerPixel), portrait ? 1 : 0),
            SIMD4(Float(gx), Float(gy), Float(notched ? -gateCorner : gateCorner), Float(d.gateSoftness)),
            SIMD4(isCleanPrint ? -1 : (format == .film35 ? 1 : 0), Float(holeCenterOffset), Float(Self.holeRadius), d.scratchesInImage ? 1 : 0),
            SIMD4(Float(d.bulge), erodesGate ? 1 : 0, Float(cos(tiltRadians)), Float(sin(tiltRadians))),
            SIMD4(Float(d.seed & 0xffff), Float(d.seed >> 16), Float(stockHalf), Float(d.gateWear)),
            SIMD4(Float(d.carrierRoughness), Float(d.carrierTail), Float(carrierHalf.along), Float(carrierHalf.across)),
            SIMD4(Float(d.edgeFog), Float(d.fogDepth), Float(d.leak),
                  Float(d.leakShape == .burn ? burnFrontDepth : d.leakSize)),
            SIMD4(Float(leak.point.0), Float(leak.point.1), Float(leak.normal.0), Float(leak.normal.1)),
            SIMD4(Float(leak.offset), Float(leak.weight), Float(d.dust), Float(d.scratches)),
            SIMD4(Float(light.x), Float(light.y), Float(light.z), Float(d.carrierWave)),
            SIMD4(Float(perforation.rawValue), Float(perforation.pitch), Float(perforation.halfAlong), Float(perforation.halfAcross)),
            SIMD4(Float(d.carrierCorner), Float(Perforation.ks1870.pitch), Float(Perforation.ks1870.halfAlong), Float(Perforation.ks1870.halfAcross)),
            SIMD4(Float(d.holeVariation), Float(d.perforationLeak), d.leakKind == .front ? 1 : 0,
                  Float(FilmEdgeDistress.LeakShape.allCases.firstIndex(of: d.leakShape)!)),
            SIMD4(Float(fogLight.x), Float(fogLight.y), Float(fogLight.z), Float(d.carrierReflection)),
            SIMD4(Float(d.carrierBlur), Float(d.carrierDetail), Float(leak.direction.0), Float(leak.direction.1)),
            SIMD4(Float(coreLight.x), Float(coreLight.y), Float(coreLight.z), Float(d.enlargerPrint ? -d.carrierTailWidth : d.carrierTailWidth)),
            SIMD4(Float(easelOffset.x), Float(easelOffset.y), Float(registration), Float(d.burnTexture)),
        ]
        for s in scratchCandidates {
            values.append(SIMD4(Float(s.across), Float(s.wander), Float(s.wavelength), Float(s.phase)))
            values.append(SIMD4(Float(s.start), Float(s.end), Float(s.width), Float(s.depth)))
            values.append(SIMD4(Float(s.slope), Float(s.dash), Float(s.bias), 0))
        }
        values.append(SIMD4(Float(neutral.x), Float(neutral.y), Float(neutral.z), Float(d.warmth)))
        values.append(SIMD4(
            Float(holderAlongHalf), Float(hairUnionBounds.minA),
            Float(hairUnionBounds.minT), Float(hairUnionBounds.maxA)))
        values.append(SIMD4(Float(hairUnionBounds.maxT), Float(activeHairs.count), 0, 0))
        for idx in 0..<3 {
            if idx < activeHairs.count {
                let h = activeHairs[idx]
                values.append(SIMD4(Float(h.minA), Float(h.minT), Float(h.maxA), Float(h.maxT)))
                values.append(SIMD4(Float(h.width), Float(h.opacity), Float(h.active), 0))
                values.append(SIMD4(Float(h.p0.x), Float(h.p0.y), Float(h.p1.x), Float(h.p1.y)))
                values.append(SIMD4(Float(h.p2.x), Float(h.p2.y), Float(h.p3.x), Float(h.p3.y)))
                values.append(SIMD4(Float(h.p4.x), Float(h.p4.y), Float(h.p5.x), Float(h.p5.y)))
                values.append(SIMD4(Float(h.p6.x), Float(h.p6.y), 0, 0))
            } else {
                for _ in 0..<6 { values.append(.zero) }
            }
        }
        return values
    }
    /// The layer exposure carried by unwanted light. Warm: through the base, mostly the red-sensitive
    /// layer (orange/red on a print). Cool: front light reaches the blue-sensitive top layer first
    /// (white/blue on a print). An empirical, uncalibrated blend around the stock's neutral response.
    static func light(neutral: SIMD3<Double>, warmth w: Double) -> SIMD3<Double> {
        if w >= 0 { return neutral * (1 - w) + SIMD3(neutral.x, neutral.x * 0.16, neutral.x * 0.04) * w }
        return neutral * (1 + w) + SIMD3(neutral.x * 0.45, neutral.y * 0.7, neutral.z) * -w
    }
    func leakLight(neutral: SIMD3<Double>) -> SIMD3<Double> { Self.light(neutral: neutral, warmth: distress.warmth) }
    /// Edge piping and perforation fog travel in the base.
    func fogLight(neutral: SIMD3<Double>) -> SIMD3<Double> { Self.light(neutral: neutral, warmth: 0.7) }
    /// Right at the cut wall the piped light reaches the green layer as well, but not the blue
    /// top layer: a yellow core on a print or inverted scan.
    func coreLight(neutral: SIMD3<Double>) -> SIMD3<Double> { SIMD3(neutral.x, neutral.y * 0.75, neutral.z * 0.08) }
    var hasExposureNoise: Bool {
        distress.edgeFog > 0 || distress.leak > 0
            || (format == .film35 && (distress.perforationLeak > 0 || distress.holeVariation > 0))
    }
}

extension EditRecipe {
    /// The layout as rendered: a negative print is always an enlarger print on an easel; scans
    /// and cinema prints never are.
    nonisolated var renderedFilmEdgeLayout: FilmEdgeLayout? {
        guard var layout = filmEdgeLayout else { return nil }
        let type = resolvedFilmEdgeType
        layout.distress.enlargerPrint = type == .negativePrint
        layout.distress.scanHolder = type == .invertedScan || type == .negativeScan
        layout.distress.invertedScan = type == .invertedScan
        return layout
    }
    /// The sheet this edit is printed on, or nil when the picture is shown as itself. A film-edge
    /// enlarger print always has one: the easel's border is part of it.
    nonisolated var printedLayout: PrintLayout? {
        if renderedFilmEdgeLayout?.distress.enlargerPrint == true { return printLayout ?? .enlargerDefault }
        return printLayout.flatMap { $0.isIdentity ? nil : $0 }
    }
    /// What goes on the sheet, for a picture or film-edge canvas of `size`.
    nonisolated func printContent(canvas size: CGSize) -> PrintGeometry.Content {
        guard let layout = renderedFilmEdgeLayout else { return .picture }
        return layout.distress.enlargerPrint ? .enlarger(frame: layout.easelFrame(canvas: size)) : .scan
    }
    /// Normalize old adaptive v5 recipes as well as live crop edits. Never mutate Develop.
    nonisolated mutating func constrainFilmEdgeCrop(imageSize: CGSize) {
        guard let filmEdgeLayout else { return }
        let upright = geometry.quarterTurns % 2 == 0 ? imageSize
            : CGSize(width: imageSize.height, height: imageSize.width)
        crop = filmEdgeLayout.constrainedCrop(crop, imageSize: upright)
    }
}
