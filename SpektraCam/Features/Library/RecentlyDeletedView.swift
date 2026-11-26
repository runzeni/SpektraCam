import SwiftUI
import UIKit

/// 30-day retention bin inside Info for soft-deleted app copies and their edits.
struct RecentlyDeletedView: View {
    let library: PhotoLibrary
    @State private var selection: Set<UUID> = []
    @State private var working = false
    @State private var confirmPurge = false
    @State private var failure: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.deletedPhotos.isEmpty {
                emptyView
            } else {
                gridView
            }
        }
        .navigationTitle(String(localized: "recently_deleted.title", defaultValue: "Recently Deleted"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !library.deletedPhotos.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    let allIDs = Set(library.deletedPhotos.map(\.id))
                    let allSelected = !allIDs.isEmpty && selection.isSuperset(of: allIDs)
                    Button(
                        allSelected
                            ? String(localized: "recently_deleted.deselect_all", defaultValue: "Deselect All")
                            : String(localized: "recently_deleted.select_all", defaultValue: "Select All")
                    ) {
                        if allSelected { selection.removeAll() } else { selection = allIDs }
                    }
                    .disabled(working)
                    .accessibilityIdentifier("recentlyDeleted.selectAll")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !library.deletedPhotos.isEmpty {
                actionBar
            }
        }
        .confirmationDialog(
            selection.count == 1
                ? String(
                    localized: "recently_deleted.purge_confirm_one",
                    defaultValue: "Permanently Delete 1 Photo?")
                : String(
                    localized: "recently_deleted.purge_confirm_many",
                    defaultValue: "Permanently Delete \(selection.count) Photos?"),
            isPresented: $confirmPurge,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "recently_deleted.delete_permanently", defaultValue: "Delete Permanently"),
                role: .destructive
            ) {
                let ids = selection
                working = true
                Task {
                    defer { working = false }
                    do {
                        try await library.purge(ids)
                        selection.subtract(ids)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(
                String(
                    localized: "recently_deleted.purge_message",
                    defaultValue:
                        "This permanently deletes the app copy and its edits from SpektraCam and cannot be undone. Originals in Apple Photos or Files are not affected."))
        }
        .failureAlert(
            String(localized: "recently_deleted.title", defaultValue: "Recently Deleted"),
            message: $failure)
        .task {
            await library.purgeExpired()
            selection.formIntersection(Set(library.deletedPhotos.map(\.id)))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await library.purgeExpired()
                    selection.formIntersection(Set(library.deletedPhotos.map(\.id)))
                }
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            String(localized: "recently_deleted.empty_title", defaultValue: "No Recently Deleted Photos"),
            systemImage: "trash",
            description: Text(
                String(
                    localized: "recently_deleted.empty_message",
                    defaultValue: "Deleted photos and edits stay here for 30 days before permanent removal.")))
        .accessibilityIdentifier("recentlyDeleted.empty")
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118), spacing: 2)],
                spacing: 2
            ) {
                let reference = Date()
                ForEach(library.deletedPhotos) { item in
                    let days = item.daysRemaining(at: reference)
                    let selected = selection.contains(item.id)
                    Button {
                        if selected { selection.remove(item.id) } else { selection.insert(item.id) }
                    } label: {
                        LibraryThumbnail(
                            photo: item.photo, images: library.images,
                            selecting: true, selected: selected
                        )
                        .overlay(alignment: .bottomLeading) {
                            Text(
                                String(
                                    localized: "recently_deleted.days_badge",
                                    defaultValue: "\(days)d")
                            )
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.68), in: .capsule)
                            .padding(6)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    .accessibilityLabel(item.photo.filename)
                    .accessibilityValue(
                        String(
                            localized: "recently_deleted.days_remaining",
                            defaultValue: "\(days) days remaining"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("recentlyDeleted.photo.\(item.id)")
                }
            }
            .padding(.bottom, 12)
        }
        .background(PhotoTheme.canvas)
        .accessibilityIdentifier("recentlyDeleted.grid")
    }

    private var actionBar: some View {
        HStack {
            Button(
                String(localized: "recently_deleted.delete_permanently", defaultValue: "Delete Permanently"),
                role: .destructive
            ) { confirmPurge = true }
            .disabled(working || selection.isEmpty)
            .accessibilityIdentifier("recentlyDeleted.deletePermanently")

            Spacer()

            Text(
                selection.isEmpty
                    ? String(
                        localized: "recently_deleted.count",
                        defaultValue: "\(library.deletedPhotos.count) items")
                    : String(
                        localized: "library.selected",
                        defaultValue: "\(selection.count) selected")
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("recentlyDeleted.count")

            Spacer()

            Button(String(localized: "recently_deleted.recover", defaultValue: "Recover")) {
                let ids = selection
                working = true
                Task {
                    defer { working = false }
                    do {
                        try await library.recover(ids)
                        selection.subtract(ids)
                    } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            .disabled(working || selection.isEmpty)
            .accessibilityIdentifier("recentlyDeleted.recover")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
