import SwiftUI

struct EditorInfoBar: View {
    let session: EditorSession
    let showingOriginal: Bool
    var location: String? = nil
    var onInteraction: (() -> Void)? = nil
    var look: LookActions? = nil
    var formulae: FormulaStrip? = nil
    var body: some View {
        let titles = EditRecipe.infoTitles(
            session.recipe, luts: session.luts,
            isRAW: session.photo.sourceDescription?.isRAW == true,
            formatLabel: session.photo.metadata.formatLabel)
        VStack(spacing: 2) {
            PhotoInfoPanel(
                title: titles.title, subtitle: titles.subtitle, metadata: session.photo.metadata,
                location: location,
                histogram: showingOriginal ? session.originalHistogram : session.histogram,
                identifier: "editor", onInteraction: onInteraction, look: look, formulae: formulae)
            if session.previewWasReduced {
                Text(
                    String(
                        localized: "editor.preview_reduced",
                        defaultValue: "Preview reduced to 720 px to fit available memory.")
                )
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
