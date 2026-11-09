import AppKit
import SwiftUI

/// The panel show/hide buttons, living in the window's titlebar.
///
/// A titlebar accessory rather than a button floating over the terminal so
/// the toggles sit on the same row as the close/minimise/zoom buttons, the
/// way Otty arranges them, and so hiding a panel gives all of its space back
/// to the terminal instead of leaving a control behind.
@MainActor
final class PanelToggleAccessory: NSTitlebarAccessoryViewController {
    private let controller: BaseTerminalController

    init(controller: BaseTerminalController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)

        let hosting = NSHostingView(rootView: PanelToggleView(controller: controller))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.frame = NSRect(x: 0, y: 0, width: 64, height: 28)
        view = container

        // Right of the title, which keeps it clear of the traffic lights at
        // the other end of the same row.
        layoutAttribute = .right
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Add the accessory to `window`, unless it already has one.
    static func install(on window: NSWindow, controller: BaseTerminalController) {
        guard !window.titlebarAccessoryViewControllers.contains(where: {
            $0 is PanelToggleAccessory
        }) else { return }
        window.addTitlebarAccessoryViewController(
            PanelToggleAccessory(controller: controller))
    }
}

private struct PanelToggleView: View {
    @ObservedObject var controller: BaseTerminalController

    var body: some View {
        HStack(spacing: 10) {
            toggle(
                icon: "sidebar.leading",
                on: controller.tabSidebarIsVisible,
                help: controller.tabSidebarIsVisible
                    ? "Hide Tab Sidebar (⌃⌘S)"
                    : "Show Tab Sidebar (⌃⌘S)"
            ) {
                controller.tabSidebarIsVisible.toggle()
            }

            toggle(
                icon: "sidebar.trailing",
                on: controller.infoPanelIsVisible,
                help: controller.infoPanelIsVisible
                    ? "Hide Info Panel (⌃⌘I)"
                    : "Show Info Panel (⌃⌘I)"
            ) {
                controller.infoPanelIsVisible.toggle()
            }
        }
        .padding(.trailing, 12)
    }

    private func toggle(
        icon: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                // A shown panel reads as the active state, which is the only
                // thing distinguishing the two otherwise identical icons.
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
