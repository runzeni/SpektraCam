import SwiftUI

/// Native horizontal scrolling keeps album navigation within reach of the photo.
struct PhotoFilmstrip: View {
    let photos: [LibraryPhoto]
    let images: LibraryImages
    @Binding var selection: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(photos) { photo in
                        Button {
                            selection = photo.id
                        } label: {
                            PhotoThumbnail(photo: photo, images: images, showsBadges: false)
                                .frame(width: 42, height: 54)
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            photo.id == selection ? Color.accentColor : .clear,
                                            lineWidth: 2.5)
                                }
                        }
                        .buttonStyle(.plain).id(photo.id)
                        .accessibilityLabel(photo.filename)
                        .accessibilityValue(
                            photo.hasEdits
                                ? String(
                                    localized: "photo.edited", defaultValue: "Edited")
                                : String(
                                    localized: "photo.original", defaultValue: "Original")
                        )
                        .accessibilityAddTraits(photo.id == selection ? .isSelected : [])
                        .accessibilityIdentifier("photo.filmstrip.\(photo.id)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: 54)
            .clipShape(.rect(cornerRadius: 6))
            .padding(7)
            .frame(height: 68)
            .frame(maxWidth: CGFloat(max(1, photos.count) * 48 + 8))
            .adaptiveGlassRect(cornerRadius: 13)
            .accessibilityIdentifier("photo.filmstrip")
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, id in
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}
