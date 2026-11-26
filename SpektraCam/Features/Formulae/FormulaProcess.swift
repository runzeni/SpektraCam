import Foundation

/// A formula read as a procedure, the way a printer notes film, paper and corrections on the
/// back of a print. It names what was chosen, in the editor's own words; the many fine
/// parameters are counted, not listed, because the file and the code carry them exactly.
@MainActor struct FormulaProcess {
    struct Row: Identifiable {
        let id: String
        let label: String
        let value: String
    }
    struct Stage: Identifiable {
        let id: EditRecipe.Part
        var title: String { id.title }
        let rows: [Row]
    }
    let stages: [Stage]
    var rowCount: Int { stages.reduce(0) { $0 + $1.rows.count } }

    init(_ formula: Formula, luts: LUTLibrary) {
        let recipe = formula.recipe
        let lookVersion = formula.partVersions[.look] ?? 2
        let exposureVersion = formula.partVersions[.exposure] ?? 2
        stages = formula.parts.compactMap { part in
            let rows: [Row] =
                switch part {
                case .look: Self.look(recipe, formula: formula, luts: luts, partVersion: lookVersion)
                case .exposure: Self.exposure(recipe, partVersion: exposureVersion)
                case .darkroom: Self.darkroom(recipe)
                }
            return rows.isEmpty ? nil : Stage(id: part, rows: rows)
        }
    }

    private static let on = String(localized: "common.on", defaultValue: "On")
    private static let off = String(localized: "common.off", defaultValue: "Off")
    private static func plain(_ value: Double, digits: Int = 2) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)))
    }
    private static func signed(_ value: Double, digits: Int = 2, unit: String = "") -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).sign(strategy: .always(includingZero: false)))
            + (unit.isEmpty ? "" : " " + unit)
    }
    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Effects a look switches on or off, named as their panels name them.
    private static let switches: [(path: String, title: String)] = [
        ("camera.diffusion_filter.active", String(localized: "effects.camera_diffusion", defaultValue: "Camera diffusion")),
        ("enlarger.diffusion_filter.active", String(localized: "effects.enlarger_diffusion", defaultValue: "Enlarger diffusion")),
        ("print_render.glare.active", String(localized: "effects.print_glare", defaultValue: "Print glare")),
    ]

    private static let lutPrefixes = [
        "film_render.grain.", "film_render.halation.",
        "camera.diffusion_filter.", "enlarger.diffusion_filter.",
    ]
    private static let namedLookNumbers: Set<String> = [
        "camera.exposure_compensation_ev", "enlarger.print_exposure",
        "enlarger.y_filter_shift", "enlarger.m_filter_shift",
    ]

    private static func toneRows(_ recipe: EditRecipe, includeTint: Bool) -> [Row] {
        var rows: [Row] = []
        let tone = recipe.tone
        if tone.contrast != 1 {
            let value =
                tone.algorithm >= 5
                ? signed((tone.contrast - 1) / 0.07, digits: 1)
                : plain(tone.contrast)
            rows.append(
                Row(
                    id: "contrast", label: String(localized: "adjust.s_curve", defaultValue: "S-curve"),
                    value: value))
            if tone.pivot != EditRecipe.Tone().pivot {
                rows.append(
                    Row(
                        id: "pivot", label: String(localized: "adjust.pivot", defaultValue: "Pivot"),
                        value: plain(tone.pivot)))
            }
        }
        if tone.highlights != 0 {
            rows.append(
                Row(
                    id: "highlights",
                    label: String(localized: "adjust.highlights", defaultValue: "Highlights"),
                    value: signed(tone.highlights)))
        }
        if tone.shadows != 0 {
            rows.append(
                Row(
                    id: "shadows", label: String(localized: "adjust.shadows", defaultValue: "Shadows"),
                    value: signed(tone.shadows)))
        }
        if includeTint, recipe.source.tint != 0 {
            rows.append(
                Row(
                    id: "tint", label: String(localized: "adjust.tint", defaultValue: "Tint"),
                    value: signed(recipe.source.tint, digits: 0)))
        }
        if recipe.source.saturation != 1 {
            rows.append(
                Row(
                    id: "saturation",
                    label: String(localized: "adjust.saturation", defaultValue: "Saturation"),
                    value: percent(recipe.source.saturation)))
        }
        if tone.monochrome {
            rows.append(
                Row(
                    id: "monochrome",
                    label: String(localized: "adjust.black_white", defaultValue: "Black & White"),
                    value: on))
        }
        return rows
    }

    private static func look(
        _ recipe: EditRecipe, formula: Formula, luts: LUTLibrary, partVersion: Int
    ) -> [Row] {
        guard recipe.look.enabled else {
            return [
                Row(
                    id: "look", label: EditRecipe.Part.look.title,
                    value: String(localized: "photo.original", defaultValue: "Original"))
            ] + toneRows(recipe, includeTint: partVersion >= 2)
        }
        var rows: [Row] = []
        let film = recipe.look.mode == .spektrafilm
        if film {
            let names = recipe.lookNames(luts: luts)
            rows.append(Row(id: "film", label: String(localized: "film_stock.film", defaultValue: "Film"), value: names.film))
            if let print = names.print {
                rows.append(Row(id: "print", label: String(localized: "develop.print", defaultValue: "Print"), value: print))
            }
            if recipe.mix != 1 {
                rows.append(Row(id: "mix", label: String(localized: "common.mix", defaultValue: "Mix"), value: percent(recipe.mix)))
            }
            if partVersion >= 2 {
                rows += legacyExposureOverrideRows(recipe)
            }
        } else {
            // A LUT that is not installed is still named, from the formula's own record of it.
            let slots = recipe.look.activeSlots.compactMap { slot -> String? in
                guard let id = slot.id else { return nil }
                let name =
                    luts.name(id) ?? formula.luts.first { $0.id == id }?.name
                    ?? String(localized: "formula.lut.unnamed", defaultValue: "Unnamed LUT")
                return slot.mix == 1 ? name : name + " " + percent(slot.mix)
            }
            rows.append(
                Row(
                    id: "lut", label: "3D LUT",
                    value: slots.isEmpty
                        ? String(localized: "lut.none_selected", defaultValue: "No LUT selected")
                        : slots.joined(separator: " · ")))
        }
        rows += toneRows(recipe, includeTint: partVersion >= 2)
        let grain = recipe.flag("film_render.grain.active")
        let grainValue =
            !grain
            ? off
            : (film && recipe.monochromeGrain
                ? String(localized: "effects.b_w_grain", defaultValue: "B&W Grain") : on)
        rows.append(
            Row(id: "grain", label: String(localized: "effects.grain", defaultValue: "Grain"), value: grainValue))
        rows.append(
            Row(
                id: "halation", label: String(localized: "effects.halation", defaultValue: "Halation"),
                value: recipe.flag("film_render.halation.active") ? on : off))
        var named: Set<String> = ["film_render.grain.active", "film_render.halation.active"]
        for effect in switches {
            let activeForMode: Bool
            if film {
                activeForMode = !recipe.bypassesPrint || (!effect.path.hasPrefix("enlarger.") && !effect.path.hasPrefix("print_render."))
            } else {
                activeForMode = effect.path != "print_render.glare.active"
            }
            guard activeForMode, recipe.flags[effect.path] != nil else { continue }
            rows.append(Row(id: effect.path, label: effect.title, value: recipe.flag(effect.path) ? on : off))
            named.insert(effect.path)
        }
        let fineNumbers = recipe.numbers.keys.filter { key in
            guard !namedLookNumbers.contains(key) else { return false }
            if film {
                return !recipe.bypassesPrint || (!key.hasPrefix("enlarger.") && !key.hasPrefix("print_render."))
            }
            return key == "camera.film_format_mm" || lutPrefixes.contains { key.hasPrefix($0) }
        }.count
        let fineFlags = recipe.flags.keys.filter { key in
            guard !named.contains(key) else { return false }
            if film {
                return !recipe.bypassesPrint || (!key.hasPrefix("enlarger.") && !key.hasPrefix("print_render."))
            }
            return lutPrefixes.contains { key.hasPrefix($0) }
        }.count
        let fineChoices = recipe.choices.keys.filter { key in
            if film {
                return !recipe.bypassesPrint || (!key.hasPrefix("enlarger.") && !key.hasPrefix("print_render."))
            }
            return lutPrefixes.contains { key.hasPrefix($0) }
        }.count
        let fine = fineNumbers + fineFlags + fineChoices
        if fine > 0 {
            rows.append(
                Row(
                    id: "fine", label: String(localized: "formula.process.fine", defaultValue: "Fine adjustments"),
                    value: String(fine)))
        }
        return rows
    }

    private static func legacyExposureOverrideRows(_ recipe: EditRecipe) -> [Row] {
        var rows: [Row] = []
        if let stops = recipe.numbers["camera.exposure_compensation_ev"] {
            rows.append(
                Row(
                    id: "compensation",
                    label: ParameterDefinition.byPath["camera.exposure_compensation_ev"]?.title ?? "",
                    value: signed(stops, unit: "EV")))
        }
        if !recipe.bypassesPrint {
            if recipe.numbers["enlarger.print_exposure"] != nil {
                rows.append(
                    Row(
                        id: "print_exposure",
                        label: String(localized: "adjust.print_exposure", defaultValue: "Print exposure"),
                        value: signed(recipe.printExposureEV, unit: "EV")))
            }
            if let yellow = recipe.numbers["enlarger.y_filter_shift"] {
                rows.append(
                    Row(
                        id: "yellow",
                        label: String(localized: "adjust.yellow_balance", defaultValue: "Yellow balance"),
                        value: signed(yellow, digits: 1, unit: "CC")))
            }
            if let magenta = recipe.numbers["enlarger.m_filter_shift"] {
                rows.append(
                    Row(
                        id: "magenta",
                        label: String(localized: "adjust.magenta_balance", defaultValue: "Magenta balance"),
                        value: signed(magenta, digits: 1, unit: "CC")))
            }
        }
        return rows
    }

    private static func exposure(_ recipe: EditRecipe, partVersion: Int) -> [Row] {
        var rows: [Row] = []
        if recipe.tone.exposureEV != 0 {
            rows.append(Row(id: "exposure", label: String(localized: "adjust.exposure", defaultValue: "Exposure"), value: signed(recipe.tone.exposureEV, unit: "EV")))
        }
        if recipe.source.exposureEV != 0 {
            rows.append(Row(id: "input", label: String(localized: "adjust.input_exposure", defaultValue: "Input exposure"), value: signed(recipe.source.exposureEV, unit: "EV")))
        }
        if let kelvin = recipe.temperature {
            rows.append(Row(id: "temperature", label: String(localized: "adjust.temperature", defaultValue: "Temperature"), value: plain(kelvin, digits: 0) + " K"))
        }
        if recipe.source.warmth != 0 {
            rows.append(
                Row(
                    id: "warmth", label: String(localized: "adjust.warmth", defaultValue: "Warmth"),
                    value: signed(recipe.source.warmth, digits: 0)))
        }
        if partVersion == 1 {
            if recipe.source.tint != 0 {
                rows.append(
                    Row(
                        id: "tint", label: String(localized: "adjust.tint", defaultValue: "Tint"),
                        value: signed(recipe.source.tint, digits: 0)))
            }
            rows += legacyExposureOverrideRows(recipe)
        }
        return rows
    }

    private static func darkroom(_ recipe: EditRecipe) -> [Row] {
        var rows: [Row] = []
        if let edge = recipe.filmEdgeLayout {
            let value: String =
                if edge.format == .roll120 {
                    "120 · " + edge.rollFrame.title
                } else {
                    switch edge.sourcePerforations {
                    case .auto: "35 mm"
                    case .stillKS: String(localized: "darkroom.perforations.still", defaultValue: "35 mm still (KS)")
                    case .cineBH: String(localized: "darkroom.perforations.cine", defaultValue: "35 mm cine (BH)")
                    }
                }
            rows.append(
                Row(
                    id: "edge", label: String(localized: "darkroom.film_edge", defaultValue: "Film edge"),
                    value: value))
        }
        if let layout = recipe.printLayout {
            rows.append(Row(id: "paper", label: String(localized: "darkroom.paper", defaultValue: "Paper"), value: layout.paper.title))
            let border: String? =
                if layout.fill {
                    String(localized: "darkroom.fill", defaultValue: "Fill")
                } else if let margin = layout.margin {
                    PrintLayout.Border(margin: margin)?.title ?? percent(margin)
                } else {
                    nil
                }
            if let border {
                rows.append(Row(id: "border", label: String(localized: "darkroom.border", defaultValue: "Border"), value: border))
            }
            if layout.handSet {
                rows.append(
                    Row(
                        id: "easel", label: String(localized: "darkroom.easel", defaultValue: "Easel"),
                        value: String(localized: "darkroom.easel.hand_set", defaultValue: "Hand-set")))
            }
        }
        if let distress = recipe.filmEdgeLayout?.distress ?? recipe.activeCleanPrintDistress,
           distress.hasCleanPrintEffects
        {
            let value = (recipe.filmEdgeLayout != nil ? distress.preset?.title : distress.cleanPrintPreset?.title)
                ?? String(localized: "darkroom.distress.custom", defaultValue: "Custom")
            rows.append(
                Row(
                    id: "distress", label: String(localized: "darkroom.distress", defaultValue: "Distress"),
                    value: value))
        }
        return rows
    }
}
