import AppKit
import Combine
import Darwin

/// The open tabs of one window, for the tab sidebar.
///
/// A "tab" in this app is a window in an `NSWindowTabGroup`, so this reads
/// AppKit's own tab list rather than keeping a parallel one that could drift
/// out of step with it.
@MainActor
final class TerminalTabsModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        /// `NSWindow.windowNumber`, which is stable for the window's lifetime.
        ///
        /// Deliberately not the window itself: this array is published, and a
        /// strong reference here would keep closed tabs alive.
        let id: Int
        let title: String
        let process: String
        let isSelected: Bool
    }

    @Published private(set) var tabs: [Tab] = []

    /// How to find the window whose tab group we report on.
    ///
    /// A closure rather than a stored window because the controller builds
    /// this model before AppKit has finished handing it a window, and because
    /// holding one here would keep a closed window alive.
    private let windowProvider: () -> NSWindow?
    private var window: NSWindow? { windowProvider() }
    private var cancellables: Set<AnyCancellable> = []

    init(window: @escaping () -> NSWindow?) {
        self.windowProvider = window

        // AppKit has no single "the tab list changed" notification, so listen
        // for the events that can change it: a tab opening or being selected
        // makes its window key, closing one posts willClose, and dragging to
        // reorder moves windows around.
        let center = NotificationCenter.default
        let names: [Foundation.Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMoveNotification,
            .ghosttyCloseTab,
            .ghosttyMoveTab,
            // These two live on Ghostty.Notification rather than on
            // Notification.Name, so they can't be written as leading-dot.
            Ghostty.Notification.ghosttyNewTab,
            Ghostty.Notification.ghosttyGotoTab,
        ]
        for name in names {
            center.publisher(for: name)
                .sink { [weak self] _ in self?.scheduleRefresh() }
                .store(in: &cancellables)
        }

        // Titles and foreground processes change without any notification
        // being posted — a `cd` or a long-running command just happens — so
        // the list is also re-read on a slow timer. The work is a title read
        // and one `proc_name` per tab, and an unchanged list is not
        // republished, so this costs nothing when nothing is happening.
        Timer.publish(every: 1.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        refresh()
    }

    /// Refresh after the current runloop turn.
    ///
    /// The notifications above fire *while* AppKit is still rearranging the
    /// tab group — a window that is closing is still in `tabGroup.windows`
    /// when `willCloseNotification` is posted — so reading it immediately
    /// would show the state we are being told is ending.
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh() {
        guard let window else {
            tabs = []
            return
        }

        // A window with no tab group is a single untabbed window, which is
        // still one tab as far as the sidebar is concerned.
        let windows = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow

        let next = windows.map { w in
            Tab(
                id: w.windowNumber,
                title: Self.title(of: w),
                process: Self.process(of: w),
                isSelected: w == (selected ?? window))
        }

        // Don't republish an identical list: this runs on several frequently
        // posted notifications and every change redraws the sidebar.
        if next != tabs { tabs = next }
    }

    /// Bring a tab to the front.
    func select(id: Int) {
        guard let window,
              let tabGroup = window.tabGroup,
              let target = tabGroup.windows.first(where: { $0.windowNumber == id })
        else { return }
        tabGroup.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    /// Close a tab.
    func close(id: Int) {
        guard let window,
              let target = (window.tabGroup?.windows ?? [window])
                .first(where: { $0.windowNumber == id })
        else { return }
        target.performClose(nil)
    }

    // MARK: - Reading a window

    private static func title(of window: NSWindow) -> String {
        // The surface's own title first: the window title lags behind it by
        // a run loop turn, so a tab opened a moment ago would otherwise show
        // the placeholder until something else forced a refresh.
        let controller = window.windowController as? BaseTerminalController
        let candidates = [
            controller?.focusedSurface?.title ?? "",
            window.title,
        ]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return "Terminal"
    }

    /// The name of the program running in the tab, e.g. `zsh` or `ssh`.
    private static func process(of window: NSWindow) -> String {
        guard let controller = window.windowController as? BaseTerminalController,
              let pid = controller.focusedSurface?.surfaceModel?.foregroundPID,
              let name = processName(pid: pid_t(pid))
        else { return "" }
        return name
    }

    /// Ask the kernel for a process name.
    ///
    /// `proc_name` rather than shelling out to `ps`: this runs for every tab
    /// on every refresh, and spawning a process each time would be far more
    /// expensive than the lookup itself.
    static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 4)
        let n = proc_name(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}
