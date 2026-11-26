import SwiftUI

/// One fixed summary height. Expanded details overlay the photo without moving it.
struct PhotoInfoPanel: View {
    static let collapsedHeight: CGFloat = 64
    static let detailsExpandedKey = "photoInfo.detailsExpanded"
    let title: String
    let subtitle: String
    let metadata: PhotoMetadata
    let location: String?
    let histogram: PhotoHistogram
    let identifier: String
    var onInteraction: (() -> Void)? = nil
    var onExpandedChange: ((Bool) -> Void)? = nil
    var maxExpandedHeight: CGFloat = 560
    /// Copy and paste for the look named in the title.
    var look: LookActions? = nil
    /// Saved formulae for this photo, below the look's own actions.
    var formulae: FormulaStrip? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @AppStorage(Self.detailsExpandedKey) private var metadataExpanded = false
    @State private var channels = false
    private var unavailable: String {
        String(localized: "photo_info.not_available", defaultValue: "Not available")
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .trailing) {
                Button(action: toggleDetails) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.caption.weight(.semibold))
                            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                        .lineLimit(1).dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        Spacer(minLength: 0)
                        Color.clear.frame(width: 112, height: 36)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: Self.collapsedHeight).contentShape(.rect)
                    .overlay(alignment: .bottom) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.bottom, 3).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier(identifier + ".info")
                .accessibilityLabel(
                    String(
                        localized: "photo_info.accessibility_summary",
                        defaultValue: "Photo information. \(title), \(subtitle)")
                )
                .accessibilityValue(
                    expanded
                        ? String(localized: "common.expanded", defaultValue: "Expanded")
                        : String(localized: "common.collapsed", defaultValue: "Collapsed"))
                Button {
                    channels.toggle()
                    onInteraction?()
                } label: {
                    VStack(spacing: 2) {
                        HistogramChart(histogram: histogram, channels: channels).frame(
                            width: 112, height: 28
                        )
                        .overlay { Rectangle().strokeBorder(.tertiary, lineWidth: 0.5) }
                        Text(
                            channels
                                ? "RGB" : String(localized: "photo_info.luma", defaultValue: "Luma")
                        ).font(.caption2.weight(.medium))
                            .dynamicTypeSize(...DynamicTypeSize.large)
                            .foregroundStyle(.secondary)
                    }.frame(width: 112).frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).padding(.trailing, 12)
                .accessibilityLabel(
                    channels
                        ? String(
                            localized: "photo_info.rgb_histogram", defaultValue: "RGB histogram")
                        : String(
                            localized: "photo_info.brightness_histogram",
                            defaultValue: "Brightness histogram")
                )
                .accessibilityHint(
                    String(
                        localized: "photo_info.histogram_hint",
                        defaultValue: "Switch brightness and RGB channels")
                )
                .accessibilityIdentifier(identifier + ".histogram")
            }
            if expanded {
                CappedHeight(maxHeight: maxExpandedHeight) {
                    detailsScrollView
                }
                .clipped()
                .allowsHitTesting(expanded)
                .transition(.opacity)
            }
        }
        .clipped()
        .adaptiveGlassRect(cornerRadius: 20)
        .onChange(of: expanded) { _, value in
            onExpandedChange?(value)
        }
        .onDisappear {
            if expanded {
                onExpandedChange?(false)
            }
        }
    }

    private var detailsScrollView: some View {
        ScrollView { detailsContent }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(0, for: .scrollContent)
            .accessibilityIdentifier(identifier + ".details")
    }

    private var detailsContent: some View {
        VStack(spacing: 6) {
            Divider()
            if let look {
                LookActionRow(actions: look, identifier: identifier)
                Divider()
            }
            if let formulae {
                formulae
                Divider()
            }
            DisclosureGroup(
                isExpanded: Binding(
                    get: { metadataExpanded },
                    set: { value in
                        onInteraction?()
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            metadataExpanded = value
                        }
                    }
                )
            ) {
                metadataRows.padding(.top, 4)
            } label: {
                Text(String(localized: "photo_info.details", defaultValue: "Photo Details"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier(identifier + ".photoDetails")
            }
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var locationDisplay: String {
        if let location, !location.isEmpty {
            return metadata.coordinateLine.map { "\(location) · \($0)" } ?? location
        }
        return metadata.coordinateLine ?? unavailable
    }

    private var metadataRows: some View {
        VStack(spacing: 5) {
            metadataRow(
                String(localized: "photo_info.location", defaultValue: "Location"),
                value: locationDisplay,
                identifier: identifier + ".location"
            )
            metadataRow(
                String(localized: "photo_info.taken", defaultValue: "Time"),
                value: metadata.capturedAt?.formatted(
                    date: .abbreviated, time: .shortened)
                    ?? unavailable,
                identifier: identifier + ".time"
            )
            metadataRow(
                String(localized: "photo_info.camera", defaultValue: "Camera"),
                value: metadata.camera?.trimmingCharacters(in: .whitespaces)
                    ?? unavailable,
                identifier: identifier + ".camera"
            )
            metadataRow(
                String(localized: "photo_info.lens", defaultValue: "Lens"),
                value: metadata.lensDisplayName ?? unavailable,
                accessibilityValue: metadata.lens ?? unavailable,
                identifier: identifier + ".lens"
            )
            metadataRow(
                String(localized: "photo_info.exposure", defaultValue: "Exposure"),
                value: metadata.exposure ?? unavailable,
                identifier: identifier + ".exposure"
            )
            metadataRow(
                String(localized: "photo_info.format", defaultValue: "Format"),
                value: metadata.sizeLine,
                identifier: identifier + ".format"
            )
            metadataRow(
                String(localized: "photo_info.color_space", defaultValue: "Color"),
                value: metadata.colorSpaceLabel,
                identifier: identifier + ".colorSpace"
            )
        }
        .font(.caption)
    }

    @ViewBuilder private func metadataRow(
        _ label: String,
        value: String,
        accessibilityValue: String? = nil,
        identifier: String
    ) -> some View {
        let row = LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
        } label: {
            Text(label)
        }
        .accessibilityIdentifier(identifier)
        if let accessibilityValue {
            row.accessibilityValue(accessibilityValue)
        } else {
            row
        }
    }
    private func toggleDetails() {
        onInteraction?()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) { expanded.toggle() }
    }
}

private struct HistogramChart: View {
    let histogram: PhotoHistogram
    let channels: Bool
    var body: some View {
        Canvas { context, size in
            let series: [([UInt], Color)] =
                channels
                ? [(histogram.red, .red), (histogram.green, .green), (histogram.blue, .blue)]
                : [(histogram.brightness, .primary)]
            let maximum = max(series.map { $0.0.max() ?? 0 }.max() ?? 0, 1)
            for (bins, color) in series {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for i in bins.indices {
                    path.addLine(
                        to: CGPoint(
                            x: CGFloat(i) / 255 * size.width,
                            y: size.height * (1 - CGFloat(bins[i]) / CGFloat(maximum))))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(channels ? 0.4 : 0.55)))
            }
        }.accessibilityHidden(true)
    }
}

struct CappedHeight: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let cap = min(proposal.height ?? maxHeight, maxHeight)
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, cap))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
