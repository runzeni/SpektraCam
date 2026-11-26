import Foundation

@main struct RecipeChecks {
    static func main() throws {
        var neutral = EditRecipe()
        neutral.look.enabled = false
        let savedNeutral = try JSONEncoder().encode(neutral)
        let decodedNeutral = try JSONDecoder().decode(EditRecipe.self, from: savedNeutral)
        precondition(decodedNeutral.look.enabled == false)
        var legacy = try JSONSerialization.jsonObject(with: savedNeutral) as! [String: Any]
        var look = legacy["look"] as! [String: Any]
        look.removeValue(forKey: "enabled")
        legacy["look"] = look
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let decodedLegacy = try JSONDecoder().decode(EditRecipe.self, from: legacyData)
        precondition(decodedLegacy.look.enabled,
            "An existing saved look must remain active")
        let all = ParameterDefinition.catalog
        precondition(Set(all.map(\.id)).count == all.count, "Duplicate parameter path")
        for field in all {
            if let value = field.defaultNumber {
                precondition(value.isFinite && field.step > 0)
                precondition(field.sliderRange.contains(value), "Default outside slider: " + field.id)
                precondition(
                    field.minimum.map { field.sliderRange.lowerBound >= $0 } ?? true,
                    "Slider below minimum: " + field.id)
                precondition(
                    field.maximum.map { field.sliderRange.upperBound <= $0 } ?? true,
                    "Slider above maximum: " + field.id)
            }
        }
        var recipe = EditRecipe()
        recipe.numbers["camera.exposure_compensation_ev"] = -2.25
        recipe.flags["film_render.grain.active"] = false
        recipe.numbers["film_render.grain.particle_area_um2"] = 0.8
        recipe.geometry.rotateLeft()
        recipe.crop.setAspect(.cinemaScope, imageAspect: 1.5)
        let processing = recipe.processingRecipe
        recipe.geometry.rotateLeft()
        recipe.crop = CropSelection()
        precondition(recipe.processingRecipe == processing, "Geometry invalidated film processing")
        recipe.temperature = 5600
        let portra = FilmStock.films.first { $0.id == "kodak_portra_400" }!
        let provia = FilmStock.films.first { $0.id == "fujifilm_provia_100f" }!
        let cinema = FilmStock.films.first { $0.id == "kodak_vision3_500t" }!
        var transition = EditRecipe()
        transition.printID = "kodak_2393"
        transition.selectFilm(provia)
        precondition(transition.scanFilm && transition.printID == "kodak_2393")
        transition.selectFilm(portra)
        precondition(
            !transition.scanFilm && transition.printID == "kodak_2393",
            "Reversal → negative retained direct scan or lost chosen print")
        transition.scanFilm = true
        transition.selectFilm(portra)
        precondition(transition.scanFilm, "Tapping the selected stock erased the explicit route")
        transition.selectFilm(cinema)
        precondition(!transition.scanFilm && cinema.category == .cinemaNegative)
        precondition(provia.category == .reversal && portra.category == .photoNegative)
        precondition(FilmStock.films.allSatisfy { FilmStock.Category.films.contains($0.category) })
        precondition(FilmStock.prints.allSatisfy { FilmStock.Category.prints.contains($0.category) })
        precondition(FilmStock.prints.filter { $0.category == .cinemaPrint }.count == 2)
        for ev in [-3.0, -1, 0, 1, 3] {
            transition.printExposureEV = ev
            precondition(abs(transition.number("enlarger.print_exposure") - pow(2, ev)) < 1e-12)
            precondition(abs(transition.printExposureEV - ev) < 1e-12)
        }
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        precondition(decoded == recipe)
        precondition(!recipe.flag("film_render.grain.active"))
        precondition(recipe.number("film_render.grain.particle_area_um2") == 0.8)
        precondition(FilmStock.films.count == 20 && FilmStock.prints.count == 8)
        recipe.filmID = "fujifilm_provia_100f"
        recipe.scanFilm = true
        precondition(recipe.bypassesPrint)
        recipe.scanFilm = false
        precondition(!recipe.bypassesPrint, "Scan/print is an explicit route")
        precondition(EditRecipe().number("film_render.halation.halation_strength[0]") == 0.015)
        recipe.filmID = "kodak_gold_200"
        precondition(recipe.number("film_render.halation.halation_strength[0]") == 0.08)
        recipe.numbers["camera.exposure_compensation_ev"] = 0
        recipe.removeDefaultOverrides()
        precondition(recipe.numbers["camera.exposure_compensation_ev"] == nil)
        try checkParts()
        try checkFormula()
        try checkFormulaLink()
        print(
            "PASS: \(all.count) parameter components, physical UI bounds, stock routes, retained values, recipe round-trip, parts and formula files"
        )
    }

    /// A pasted part replaces that part and nothing else, whatever the target held before.
    static func checkParts() throws {
        typealias Part = EditRecipe.Part
        var source = EditRecipe()
        source.filmID = "kodak_gold_200"
        source.printID = "kodak_2393"
        source.look.mode = .lut
        source.look.first.id = String(repeating: "a", count: 64)
        source.tone.contrast = 1.2
        source.tone.exposureEV = 0.7
        source.tone.monochrome = true
        source.monochromeGrain = true
        source.mix = 0.5
        source.source = .init(exposureEV: 0.3, warmth: 12, tint: -4, saturation: 0.8)
        source.temperature = 4800
        source.numbers["film_render.grain.particle_area_um2"] = 0.8
        source.numbers["camera.exposure_compensation_ev"] = 1.5
        source.numbers["enlarger.y_filter_shift"] = 9
        source.numbers["enlarger.m_filter_shift"] = -6
        source.printExposureEV = 0.5
        source.flags["camera.auto_exposure"] = false
        source.choices["enlarger.illuminant"] = "x"
        var paper = PrintLayout()
        paper.paper = .eightByTen
        source.printLayout = paper
        source.filmEdgeSelection = FilmEdgeSelection()
        source.filmEdgeLayout = FilmEdgeLayout()
        source.geometry.rotateLeft()
        source.crop.setAspect(.cinemaScope, imageAspect: 1.5)

        var target = EditRecipe()
        target.filmID = "fujifilm_provia_100f"
        target.tone.exposureEV = -1
        target.tone.shadows = 0.4
        target.source.tint = 3
        target.temperature = 6100
        target.numbers["film_render.grain.particle_area_um2"] = 0.3
        target.numbers["film_render.halation.scatter_amount"] = 0.9  // Must not survive a new Look.
        target.numbers["enlarger.y_filter_shift"] = 2
        target.flags["film_render.grain.active"] = false
        target.geometry.rotateLeft()
        target.geometry.rotateLeft()
        target.crop.setAspect(.square, imageAspect: 1.5)

        precondition(target.taking([], from: source, rawTarget: true) == target, "No part changed the photo")

        let look = target.taking([.look], from: source, rawTarget: true)
        precondition(look.filmID == source.filmID && look.printID == source.printID && look.look == source.look)
        precondition(look.tone.contrast == 1.2 && look.tone.monochrome && look.tone.shadows == 0)
        precondition(look.tone.exposureEV == -1, "Look replaced the photo's exposure")
        precondition(look.source.saturation == 0.8 && look.source.tint == -4 && look.source.warmth == 0,
            "Look did not preserve source tint or leaked source warmth")
        precondition(look.temperature == 6100, "Look changed the RAW target's color temperature")
        precondition(look.numbers["film_render.grain.particle_area_um2"] == 0.8)
        precondition(look.numbers["film_render.halation.scatter_amount"] == nil, "The old look's override leaked")
        precondition(look.numbers["enlarger.y_filter_shift"] == 9 && look.numbers["enlarger.m_filter_shift"] == -6,
            "Look dropped the print balance adjustments")
        precondition(look.numbers["camera.exposure_compensation_ev"] == 1.5,
            "Look dropped film exposure compensation")
        precondition(abs(look.printExposureEV - 0.5) < 1e-12, "Look dropped print exposure")
        precondition(look.flags == source.flags && look.choices == source.choices)
        precondition(look.monochromeGrain && look.mix == 0.5)
        precondition(look.printLayout == nil && look.filmEdgeLayout == nil, "Look carried the Darkroom")
        precondition(look.crop == target.crop && look.geometry == target.geometry, "Look moved the framing")

        let exposure = target.taking([.exposure], from: source, rawTarget: true)
        precondition(exposure.filmID == target.filmID && exposure.look == target.look)
        precondition(exposure.tone.exposureEV == 0.7 && exposure.tone.shadows == 0.4)
        precondition(exposure.source.exposureEV == 0.3 && exposure.source.warmth == 12 && exposure.source.tint == 3,
            "Exposure did not carry warmth/exposure or overwrote Look tint")
        precondition(exposure.source.saturation == 1, "Saturation belongs to the Look")
        precondition(exposure.temperature == 4800)
        precondition(target.taking([.exposure], from: source, rawTarget: false).temperature == 6100,
            "A RAW white balance reached a rendered photo")
        var autoRAWSource = EditRecipe()
        autoRAWSource.tone.exposureEV = 0.4
        precondition(target.taking([.exposure], from: autoRAWSource, rawTarget: true).temperature == nil,
            "Auto RAW source exposure did not reset target RAW temperature to Auto WB")
        precondition(target.taking([.look], from: autoRAWSource, rawTarget: true).temperature == 6100,
            "Look-only changed the RAW target's color temperature")
        precondition(exposure.numbers["camera.exposure_compensation_ev"] == nil)
        precondition(exposure.numbers["enlarger.y_filter_shift"] == 2 && exposure.numbers["enlarger.m_filter_shift"] == nil)
        precondition(exposure.printExposureEV == 0)
        precondition(exposure.numbers["film_render.grain.particle_area_um2"] == 0.3)
        precondition(exposure.numbers["film_render.halation.scatter_amount"] == 0.9)
        precondition(exposure.flags == target.flags)

        let darkroom = target.taking([.darkroom], from: source, rawTarget: true)
        precondition(darkroom.printLayout == source.printLayout && darkroom.filmEdgeLayout == source.filmEdgeLayout)
        precondition(darkroom.filmEdgeSelection == source.filmEdgeSelection)
        precondition(darkroom.distress == source.distress)
        precondition(darkroom.processingRecipe == target.processingRecipe, "Darkroom changed the film render")
        precondition(darkroom.crop == target.crop && darkroom.geometry == target.geometry)

        // Clean-print distress travels strictly inside Part.darkroom and cleans up default .clean overrides.
        var distressedTarget = target
        var cleanLeak = FilmEdgeDistress.cleanPrintFallback
        cleanLeak.applyCleanPrintPreset(.leaky)
        distressedTarget.distress = cleanLeak
        precondition(distressedTarget.has(.darkroom))
        let copiedDistress = target.taking([.darkroom], from: distressedTarget, rawTarget: true)
        precondition(copiedDistress.distress == cleanLeak)
        precondition(copiedDistress.processingRecipe == target.processingRecipe, "Clean-print distress altered film processing")
        let clearedDistress = distressedTarget.taking([.darkroom], from: EditRecipe(), rawTarget: true)
        precondition(clearedDistress.distress == nil)
        var defaultClean = EditRecipe()
        defaultClean.distress = FilmEdgeDistress.cleanPrintFallback
        defaultClean.removeDefaultOverrides()
        precondition(defaultClean.distress == nil)

        // All parts together are the source with the target's framing.
        var expected = source
        expected.crop = target.crop
        expected.geometry = target.geometry
        expected.removeDefaultOverrides()
        precondition(target.taking(Set(Part.allCases), from: source, rawTarget: true) == expected)
        // The three parts are independent: any order gives the same result.
        let stepwise = target.taking([.darkroom], from: source, rawTarget: true)
            .taking([.exposure], from: source, rawTarget: true).taking([.look], from: source, rawTarget: true)
        precondition(stepwise == expected, "Parts overlap")

        precondition(EditRecipe().has(.look) && !EditRecipe().has(.exposure) && !EditRecipe().has(.darkroom))
        precondition(source.has(.exposure) && source.has(.darkroom))
        var balanced = EditRecipe()
        balanced.numbers["enlarger.m_filter_shift"] = 4
        precondition(!balanced.has(.exposure) && balanced.taking([.look], from: balanced, rawTarget: true).numbers["enlarger.m_filter_shift"] == 4,
            "Print balance belongs to the Look")
        var warmed = EditRecipe()
        warmed.look.enabled = false
        warmed.source.warmth = 10
        precondition(!warmed.hasEditedLook && warmed.has(.exposure),
            "Warmth belongs to Exposure & WB")
        let clip = LookClip(source)
        precondition(clip.recipe.crop == CropSelection() && clip.recipe.geometry.isIdentity, "A clip kept framing")
        precondition(clip.parts == Part.allCases)
        precondition(clip.removingLUTs(source.look.identifiers).recipe.look.first.id == nil)
    }

    /// A formula file keeps only its parts, reads back the same, and survives a newer writer.
    static func checkFormula() throws {
        let lut = String(repeating: "b", count: 64)
        var edit = EditRecipe()
        edit.filmID = "kodak_gold_200"
        edit.look.mode = .lut
        edit.look.first.id = lut
        edit.tone.exposureEV = 0.7
        edit.tone.contrast = 1.2
        edit.numbers["enlarger.y_filter_shift"] = 9
        edit.numbers["film_render.grain.particle_area_um2"] = 0.8
        var paper = PrintLayout()
        paper.paper = .fiveBySeven
        edit.printLayout = paper
        edit.geometry.rotateLeft()
        let references = [Formula.LUT(id: lut, name: "Warm", size: 33), Formula.LUT(id: String(repeating: "c", count: 64), name: "Unused", size: 17)]

        let formula = try Formula(name: "  Tungsten night ", note: " f/8 ", parts: [.look, .darkroom], from: edit, luts: references)
        precondition(formula.name == "Tungsten night" && formula.note == "f/8")
        precondition(formula.parts == [.look, .darkroom] && formula.unreadable.isEmpty)
        precondition(formula.recipe.tone.exposureEV == 0,
            "A part the author left out was written to the file")
        precondition(formula.recipe.numbers["enlarger.y_filter_shift"] == 9,
            "Print balance was dropped from Look")
        precondition(formula.recipe.tone.contrast == 1.2 && formula.recipe.printLayout == paper)
        precondition(formula.recipe.geometry.isIdentity, "A formula kept framing")
        precondition(formula.luts.map(\.name) == ["Warm"], "Only LUTs the look uses are listed")
        precondition(formula.missingLUTs(installed: []).map(\.name) == ["Warm"] && formula.missingLUTs(installed: [lut]).isEmpty)
        precondition((try? Formula(name: " ", parts: [.look], from: edit, luts: [])) == nil, "An empty name was accepted")
        let lookOnly = try Formula(name: "Look", parts: [.look], from: edit, luts: references)
        precondition(lookOnly.recipe.printLayout == nil && lookOnly.parts == [.look])
        let darkroomOnly = try Formula(name: "Border", parts: [.darkroom], from: edit, luts: references)
        precondition(darkroomOnly.luts.isEmpty && darkroomOnly.missingLUTs(installed: []).isEmpty)
        precondition(darkroomOnly.recipe.processingRecipe == EditRecipe().processingRecipe)

        // Switching to Spektrafilm with a dormant LUT id retained in the slot must not export any
        // LUT metadata or require that LUT when the formula is saved or shared.
        var filmWithDormantLUT = edit
        filmWithDormantLUT.look.enabled = true
        filmWithDormantLUT.look.mode = .spektrafilm
        precondition(filmWithDormantLUT.look.activeSlots.isEmpty && filmWithDormantLUT.look.activeIdentifiers.isEmpty)
        let filmDormantFormula = try Formula(name: "Spektrafilm", parts: [.look], from: filmWithDormantLUT, luts: references)
        precondition(filmDormantFormula.luts.isEmpty && filmDormantFormula.missingLUTs(installed: []).isEmpty)
        precondition(filmDormantFormula.recipe.look.first.id == nil && filmDormantFormula.recipe.look.second.id == nil)

        // Original mode must also ignore dormant LUTs and unedited tones.
        var originalWithDormant = filmWithDormantLUT
        originalWithDormant.look.enabled = false
        originalWithDormant.tone = EditRecipe.Tone()
        precondition(!originalWithDormant.hasEditedLook)
        let originalFormula = try Formula(name: "Original", parts: [.look], from: originalWithDormant, luts: references)
        precondition(originalFormula.luts.isEmpty && originalFormula.recipe.look.first.id == nil)

        // A 0-mix secondary LUT slot is inactive and excluded from LUT requirements.
        let secondLUT = String(repeating: "d", count: 64)
        var singleActiveLUT = edit
        singleActiveLUT.look.enabled = true
        singleActiveLUT.look.mode = .lut
        singleActiveLUT.look.first.mix = 0.8
        singleActiveLUT.look.second = .init(id: secondLUT, mix: 0)
        precondition(singleActiveLUT.look.activeIdentifiers == [lut])
        let activeFormula = try Formula(
            name: "Single LUT", parts: [.look], from: singleActiveLUT,
            luts: references + [Formula.LUT(id: secondLUT, name: "Muted", size: 17)])
        precondition(activeFormula.luts.map(\.id) == [lut] && activeFormula.recipe.look.second.id == nil)
        precondition(activeFormula.missingLUTs(installed: [lut]).isEmpty)

        // Extended S-curve values (±10 -> 0.30...1.70) survive sanitization and FormulaLink round-trip.
        for extreme in [0.30, 1.70] {
            var wide = EditRecipe()
            wide.tone.contrast = extreme
            let f = try Formula(name: "Extreme", parts: [.look], from: wide, luts: [])
            let back = try Formula(data: try FormulaLink.file(from: try FormulaLink.url(for: f.data()).absoluteString))
            precondition(abs(back.recipe.tone.contrast - extreme) < 1e-9, "S-curve contrast was clipped: \(back.recipe.tone.contrast)")
        }

        // Unedited RAW camera temperature matches neutralTemperature and is not treated as an exposure edit.
        var rawRecipe = EditRecipe()
        rawRecipe.temperature = 5200
        rawRecipe.tone.exposureEV = 1.1
        rawRecipe.source.tint = -8
        rawRecipe.numbers["camera.exposure_compensation_ev"] = 0.5
        rawRecipe.numbers["enlarger.y_filter_shift"] = 6
        precondition(rawRecipe.hasEditedLook, "Tint/film exposure edit must mark Look as edited")
        var rawLookCheck = EditRecipe()
        rawLookCheck.temperature = 5200
        precondition(!rawLookCheck.has(.exposure, neutralTemperature: 5200))
        precondition(rawLookCheck.has(.exposure, neutralTemperature: 6500))
        let rawLookOnly = try Formula(
            name: "RAW Look", parts: [.look], from: rawRecipe, luts: [], neutralTemperature: 5200)
        precondition(rawLookOnly.recipe.temperature == nil && rawLookOnly.recipe.tone.exposureEV == 0,
            "Formula Look kept exposure or RAW color temperature")
        precondition(rawLookOnly.recipe.source.tint == -8
            && rawLookOnly.recipe.numbers["camera.exposure_compensation_ev"] == 0.5
            && rawLookOnly.recipe.numbers["enlarger.y_filter_shift"] == 6,
            "Formula Look dropped source tint, film exposure, or print balance")
        var secondRAW = EditRecipe()
        secondRAW.temperature = 6400
        secondRAW.tone.exposureEV = -0.5
        let appliedToSecond = secondRAW.taking(Set(rawLookOnly.parts), from: rawLookOnly.recipe, rawTarget: true)
        precondition(
            appliedToSecond.temperature == 6400 && appliedToSecond.tone.exposureEV == -0.5
                && appliedToSecond.source.tint == -8
                && appliedToSecond.numbers["camera.exposure_compensation_ev"] == 0.5
                && appliedToSecond.numbers["enlarger.y_filter_shift"] == 6,
            "Applying Formula Look altered target RAW temperature/exposure or lost Look settings")
        let rawAutoWBWithExposure = try Formula(
            name: "RAW Auto WB + Exposure", parts: [.look, .exposure], from: rawRecipe, luts: [],
            neutralTemperature: 5200)
        precondition(rawAutoWBWithExposure.recipe.temperature == nil && rawAutoWBWithExposure.recipe.tone.exposureEV == 1.1,
            "Untouched RAW temperature was not kept as Auto WB (nil)")
        let appliedAutoToSecond = secondRAW.taking(
            Set(rawAutoWBWithExposure.parts), from: rawAutoWBWithExposure.recipe, rawTarget: true)
        precondition(appliedAutoToSecond.temperature == nil && appliedAutoToSecond.tone.exposureEV == 1.1,
            "Applying Formula with Auto RAW WB did not keep target RAW on Auto WB (nil)")

        let data = try formula.data()
        let read = try Formula(data: data)
        precondition(read == formula, "A formula file did not read back the same")

        // A newer SpektraCam: a later Darkroom version, a paper this build cannot name, a part and
        // fields it has never heard of. The Look still applies and nothing is lost on rename.
        var file = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var versions = file["parts"] as! [String: Any]
        versions["darkroom"] = 2
        versions["framing"] = 1
        file["parts"] = versions
        file["futureField"] = ["kept": true]
        var stored = file["recipe"] as! [String: Any]
        var layout = stored["printLayout"] as! [String: Any]
        layout["paper"] = "elevenByFourteen"
        stored["printLayout"] = layout
        file["recipe"] = stored
        let newer = try JSONSerialization.data(withJSONObject: file)
        let partial = try Formula(data: newer)
        precondition(partial.parts == [.look] && partial.unreadable == ["darkroom", "framing"])
        precondition(partial.recipe.printLayout == nil && partial.recipe.tone.contrast == 1.2)
        versions["darkroom"] = 1
        file["parts"] = versions
        let unnamed = try Formula(data: JSONSerialization.data(withJSONObject: file))
        precondition(unnamed.parts == [.look] && unnamed.unreadable.contains("darkroom"),
            "An unknown paper made the whole formula unreadable")
        let renamed = try Formula.renaming(newer, name: "Renamed", note: "")
        let kept = try JSONSerialization.jsonObject(with: renamed) as! [String: Any]
        precondition(kept["name"] as? String == "Renamed" && (kept["futureField"] as? [String: Any])?["kept"] as? Bool == true)
        precondition(((kept["recipe"] as! [String: Any])["printLayout"] as! [String: Any])["paper"] as? String == "elevenByFourteen",
            "Renaming stripped settings this build cannot read")
        let copy = try Formula.duplicating(data, name: "Copy")
        let duplicate = try Formula(data: copy.data)
        precondition(duplicate.id == copy.id && duplicate.id != formula.id && duplicate.recipe == formula.recipe)

        // Tagged v1.0 Formula files keep v1 part semantics: Exposure owns tint & film/print overrides.
        var v1Target = EditRecipe()
        v1Target.source.tint = 3
        v1Target.numbers["enlarger.y_filter_shift"] = 5
        v1Target.temperature = 6100
        let v1ExposureJSON = Data("""
        {
          "created": "2026-11-20T00:00:00Z",
          "format": 1,
          "id": "11111111-1111-1111-1111-111111111111",
          "luts": [],
          "name": "v1 Exposure Only",
          "note": "",
          "parts": { "exposure": 1 },
          "recipe": {
            "numbers": { "enlarger.y_filter_shift": 12 },
            "source": { "exposureEV": 0, "saturation": 1, "tint": -8, "warmth": 0 },
            "version": 5
          }
        }
        """.utf8)
        let v1Exposure = try Formula(data: v1ExposureJSON)
        precondition(v1Exposure.partVersions == [.exposure: 1])
        let appliedV1Exposure = v1Exposure.applied(to: v1Target, rawTarget: true)
        precondition(appliedV1Exposure.source.tint == -8 && appliedV1Exposure.numbers["enlarger.y_filter_shift"] == 12,
            "v1.0 Exposure-only formula lost tint or yellow-balance override")
        precondition(appliedV1Exposure.temperature == 6100,
            "v1.0 Exposure-only formula without saved temperature cleared target RAW temperature")
        let v1ExposureRoundTrip = try Formula(data: try v1Exposure.data())
        precondition(v1ExposureRoundTrip.partVersions == [.exposure: 1],
            "Re-encoding a v1.0 formula bumped its stored part version")

        let v1LookJSON = Data("""
        {
          "created": "2026-11-20T00:00:00Z",
          "format": 1,
          "id": "22222222-2222-2222-2222-222222222222",
          "luts": [],
          "name": "v1 Look Only",
          "note": "",
          "parts": { "look": 1 },
          "recipe": {
            "filmID": "fujifilm_c200",
            "version": 5
          }
        }
        """.utf8)
        let v1Look = try Formula(data: v1LookJSON)
        precondition(v1Look.partVersions == [.look: 1])
        let appliedV1Look = v1Look.applied(to: v1Target, rawTarget: true)
        precondition(appliedV1Look.source.tint == 3 && appliedV1Look.numbers["enlarger.y_filter_shift"] == 5
            && appliedV1Look.filmID == "fujifilm_c200",
            "v1.0 Look-only formula overwrote target tint or yellow-balance override")
        precondition(formula.partVersions == [.look: 2, .darkroom: 1],
            "Newly saved v1.1 formula did not record part versions")

        // Files are untrusted: unknown paths go, values are held to each control's limits.
        stored = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["recipe"] as! [String: Any]
        stored["numbers"] = ["made.up": 4.0, "film_render.grain.particle_area_um2": -50.0, "enlarger.print_exposure": 1e300]
        stored["mix"] = 7.0
        var look = stored["look"] as! [String: Any]
        look["first"] = ["id": "../../etc", "mix": 1.0]
        stored["look"] = look
        file = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        file["recipe"] = stored
        let hostile = try Formula(data: JSONSerialization.data(withJSONObject: file))
        precondition(hostile.recipe.numbers["made.up"] == nil && hostile.recipe.mix == 1)
        precondition(hostile.recipe.look.first.id == nil, "A LUT id that is not a hash was kept")
        let area = ParameterDefinition.byPath["film_render.grain.particle_area_um2"]!
        precondition(hostile.recipe.number("film_render.grain.particle_area_um2") >= (area.minimum ?? -.infinity))
        precondition(hostile.recipe.number("enlarger.print_exposure").isFinite)
        // A shared copy may carry its LUT files; the kept copy never does.
        let cube = Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
        let carried = try Formula.attaching(data, luts: [(name: "Warm", cube: cube)])
        let found = Formula.attachments(in: carried)
        precondition(found.count == 1 && found[0].cube == cube && found[0].id == Formula.hash(cube))
        let readCarried = try Formula(data: carried, limit: Formula.sharedLimit)
        let keptFile = try Formula.strippingAttachments(carried)
        let readKept = try Formula(data: keptFile)
        precondition(readCarried == formula && readKept == formula && Formula.attachments(in: keptFile).isEmpty)
        let untouched = try Formula.strippingAttachments(data)
        precondition(untouched == data, "A file without LUTs was rewritten")
        var forged = try JSONSerialization.jsonObject(with: carried) as! [String: Any]
        forged["attachments"] = [["id": lut, "name": "Warm", "cube": String(decoding: cube, as: UTF8.self)]]
        let forgedData = try JSONSerialization.data(withJSONObject: forged)
        precondition(Formula.attachments(in: forgedData).isEmpty, "A LUT that does not match its id was accepted")
        let other = Formula.LUT(id: Formula.hash(cube), name: "Other", size: 2)
        let relinked = try Formula(data: Formula.replacingLUT(data, lut, with: other))
        precondition(relinked.recipe.look.first.id == other.id && relinked.luts == [other])
        precondition(relinked.recipe.tone.contrast == 1.2 && relinked.id == formula.id)
        file["format"] = 2
        do {
            _ = try Formula(data: JSONSerialization.data(withJSONObject: file))
            preconditionFailure("A newer file format was read as if it were known")
        } catch Formula.Failure.newer {}
        precondition((try? Formula(data: Data("{}".utf8))) == nil && (try? Formula(data: Data("no".utf8))) == nil)
    }

    /// A link carries the whole formula file, including what this build cannot read, and
    /// nothing that is not a formula link is taken for one.
    static func checkFormulaLink() throws {
        var edit = EditRecipe()
        edit.filmID = "fujifilm_c200"
        edit.printID = "fujifilm_crystal_archive_typeii"
        edit.tone.contrast = 1.15
        edit.numbers["film_render.grain.particle_area_um2"] = 0.8
        edit.printLayout = PrintLayout.enlargerDefault
        edit.filmEdgeLayout = FilmEdgeLayout.newDefault()
        let formula = try Formula(name: "夜のタングステン / Tungsten", note: "f/8 · 1/60", parts: [.look, .darkroom], from: edit, luts: [])
        var object = try JSONSerialization.jsonObject(with: formula.data()) as! [String: Any]
        object["futureField"] = ["kept": [1, 2, 3]]
        let file = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])

        let link = try FormulaLink.url(for: file).absoluteString
        precondition(link.hasPrefix("https://runzeni.github.io/spektracam/f#1."), "Unexpected link: " + link.prefix(60))
        precondition(link.utf8.count <= FormulaLink.codeLimit, "A film-edge formula no longer fits a code: \(link.utf8.count)")
        precondition(link.dropFirst(FormulaLink.page.count + 1).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) },
            "The formula is not URL-safe")
        func read(_ text: String) -> Data? { try? FormulaLink.file(from: text) }
        let back = try FormulaLink.file(from: "  " + link + "\n")
        let (sent, received) = (try Formula(data: file), try Formula(data: back))
        precondition(sent == received && received.parts == [.look, .darkroom], "A link changed the formula")
        var kept = try JSONSerialization.jsonObject(with: file) as! [String: Any]
        var stored = kept["recipe"] as! [String: Any]
        precondition(FormulaLink.framing.allSatisfy { stored[$0] != nil }, "The stored file no longer names its framing")
        for key in FormulaLink.framing { stored[key] = nil }
        kept["recipe"] = stored
        let same = try JSONSerialization.jsonObject(with: back) as! NSDictionary
        precondition(same == kept as NSDictionary, "A link dropped fields this build cannot read")
        // The app's own scheme, and the page with a trailing slash or in another case.
        let direct = try FormulaLink.url(for: file, opensApp: true).absoluteString
        precondition(direct.hasPrefix("spektracam://f#1.") && read(direct) == back)
        let payload = String(link.dropFirst(FormulaLink.page.count))
        precondition(read("https://Runzeni.github.io/SpektraCam/f/" + payload) == back)
        precondition(read("https://runzeni.github.io/spektracam/f/index.html" + payload) == back)
        // LUT files never ride in a link.
        let cube = Data("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)
        let carried = try FormulaLink.file(from: FormulaLink.url(for: Formula.attaching(file, luts: [(name: "Warm", cube: cube)])).absoluteString)
        precondition(Formula.attachments(in: carried).isEmpty && carried == back)

        precondition(FormulaLink.claims(link) && FormulaLink.claims(direct))
        for other in ["https://example.com/f" + payload, "https://runzeni.github.io/", "https://runzeni.github.io/other" + payload, "file:///tmp/a.rnformula", ""] {
            precondition(!FormulaLink.claims(other) && read(other) == nil, "Taken for a formula link: " + other)
        }
        for broken in ["#1.", "#1.!!!!", "#1.AAAA", "#abc", "#" + payload.dropFirst(4)] {
            precondition(read(FormulaLink.page + broken) == nil, "A broken link was read: " + broken)
        }
        do {
            _ = try FormulaLink.file(from: FormulaLink.page + "#2." + payload.dropFirst(3))
            preconditionFailure("A newer packing was read as if it were known")
        } catch Formula.Failure.newer {}
        precondition(read(FormulaLink.page + "#1." + String(repeating: "A", count: FormulaLink.limit)) == nil)
        print("formula link: \(file.count) byte file -> \(link.utf8.count) characters")
    }
}
