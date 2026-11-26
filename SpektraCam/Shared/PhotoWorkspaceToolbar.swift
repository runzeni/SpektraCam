import SwiftUI
import UIKit

/// The same camera action occupies the trailing corner of every photo workspace.
/// Library keeps its prominent floating camera control.
struct PhotoWorkspaceCameraToolbar: ToolbarContent {
    var body: some ToolbarContent {
        AdaptiveToolbarItem(placement: .topBarTrailing, background: .hidden) { CameraButton() }
    }
}

struct WorkspaceHistoryItem {
    var title: String
    var systemImage: String? = nil
    var identifier: String? = nil
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    var action: () -> Void
}

/// Shared circular history menu trigger for Editor (`History`) and Photos (`Revert`).
/// Navigation-bar items use a UIKit menu button hosting `PhotoActionMenuLabel` so `ToolbarItem`
/// keeps the exact `44 × 44` circle styling; floating controls use a native SwiftUI `Menu`.
struct WorkspaceHistoryMenu: View {
    enum Placement { case floating, navigationBar, systemBar }

    let title: String
    let identifier: String
    var placement: Placement = .floating
    let sections: [[WorkspaceHistoryItem]]

    var body: some View {
        switch placement {
        case .systemBar:
            Menu(title, systemImage: "arrow.uturn.backward") {
                menuSections
            }
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
        case .floating, .navigationBar:
            ToolbarHistoryMenu(title: title, identifier: identifier, sections: sections)
                .frame(width: 44, height: 44)
        }
    }

    @ViewBuilder private var menuSections: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            if !section.isEmpty {
                Section {
                    ForEach(Array(section.enumerated()), id: \.offset) { _, item in
                        systemHistoryButton(item)
                    }
                }
            }
        }
    }

    @ViewBuilder private func systemHistoryButton(_ item: WorkspaceHistoryItem) -> some View {
        let base = Group {
            if let systemImage = item.systemImage {
                Button(
                    item.title,
                    systemImage: systemImage,
                    role: item.isDestructive ? .destructive : nil,
                    action: item.action
                )
            } else {
                Button(
                    item.title,
                    role: item.isDestructive ? .destructive : nil,
                    action: item.action
                )
            }
        }
        .disabled(!item.isEnabled)

        if let itemIdentifier = item.identifier {
            base.accessibilityIdentifier(itemIdentifier)
        } else {
            base
        }
    }
}

private struct ToolbarHistoryMenu: UIViewRepresentable {
    let title: String
    let identifier: String
    let sections: [[WorkspaceHistoryItem]]

    func makeUIView(context: Context) -> ContainerView {
        ContainerView()
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.configure(
            title: title,
            identifier: identifier,
            isEnabled: context.environment.isEnabled,
            colorScheme: context.environment.colorScheme,
            accent: context.environment.appAccent,
            sections: sections
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ContainerView, context: Context) -> CGSize? {
        CGSize(width: 44, height: 44)
    }

    final class ContainerView: UIView {
        private final class HighlightButton: UIButton {
            var onHighlightChanged: ((Bool) -> Void)?
            override var isHighlighted: Bool {
                didSet {
                    if oldValue != isHighlighted { onHighlightChanged?(isHighlighted) }
                }
            }
        }

        private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
        private let button = HighlightButton(type: .custom)
        private var currentTitle = ""
        private var currentEnabled = true
        private var currentColorScheme: ColorScheme = .dark
        private var currentAccent: AppAccent = .magenta

        init() {
            super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
            backgroundColor = .clear
            hosting.safeAreaRegions = []
            hosting.view.backgroundColor = .clear
            hosting.view.isUserInteractionEnabled = false
            hosting.view.accessibilityElementsHidden = true
            addSubview(hosting.view)

            button.backgroundColor = .clear
            button.showsMenuAsPrimaryAction = true
            button.onHighlightChanged = { [weak self] _ in self?.refreshLabel() }
            addSubview(button)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 44) }

        override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 44, height: 44) }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosting.view.frame = bounds
            button.frame = bounds
        }

        private func refreshLabel() {
            hosting.rootView = AnyView(
                PhotoActionMenuLabel(
                    title: currentTitle,
                    systemImage: "arrow.uturn.backward",
                    isPressed: button.isHighlighted
                )
                .environment(\.isEnabled, currentEnabled)
                .environment(\.colorScheme, currentColorScheme)
                .environment(\.appAccent, currentAccent)
            )
        }

        func configure(
            title: String,
            identifier: String,
            isEnabled: Bool,
            colorScheme: ColorScheme,
            accent: AppAccent,
            sections: [[WorkspaceHistoryItem]]
        ) {
            currentTitle = title
            currentEnabled = isEnabled
            currentColorScheme = colorScheme
            currentAccent = accent
            refreshLabel()
            button.isEnabled = isEnabled
            button.accessibilityLabel = title
            button.accessibilityIdentifier = identifier
            button.menu = UIMenu(
                title: "",
                children: sections.compactMap { items in
                    guard !items.isEmpty else { return nil }
                    let actions = items.map { item -> UIAction in
                        var attributes: UIMenuElement.Attributes = []
                        if !item.isEnabled { attributes.insert(.disabled) }
                        if item.isDestructive { attributes.insert(.destructive) }
                        let action = UIAction(
                            title: item.title,
                            image: item.systemImage.flatMap { UIImage(systemName: $0) },
                            attributes: attributes
                        ) { _ in
                            item.action()
                        }
                        if let itemIdentifier = item.identifier {
                            action.accessibilityIdentifier = itemIdentifier
                        }
                        return action
                    }
                    return UIMenu(title: "", options: .displayInline, children: actions)
                }
            )
        }
    }
}
