import AppKit
import SwiftUI

/// The quick "connect to…" panel, opened with ⌘⇧S.
///
/// A panel rather than a window so it floats over the terminal and gives key
/// focus back when it closes, which is what makes it feel like a picker
/// rather than a second window to manage.
@MainActor
final class SSHConnectionPickerController: NSWindowController, NSWindowDelegate {
    static let shared = SSHConnectionPickerController()

    private let model = PickerModel()

    private init() {
        let size = NSSize(width: 520, height: 420)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // A picker is dismissed with escape or by clicking away, so the
        // window buttons would only be clutter over the search field.
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }

        super.init(window: panel)

        panel.delegate = self
        // Size the SwiftUI root explicitly: a hosting controller otherwise
        // shrinks the panel to the content's intrinsic height, and a list in
        // a ScrollView has none, which collapses the whole thing.
        panel.contentViewController = NSHostingController(
            rootView: SSHConnectionPickerView(model: model)
                .frame(width: size.width, height: size.height))
        panel.setContentSize(size)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Open the picker, or close it if it is already up.
    func toggle() {
        if window?.isVisible == true {
            close()
            return
        }
        show()
    }

    func show() {
        guard let window else { return }

        // Remember who to hand the tab to: opening the panel takes key status
        // away from the terminal, so by the time a connection is chosen there
        // is no "frontmost terminal" left to infer it from.
        model.parentWindow = TerminalController.preferredParent?.window
        model.onDismiss = { [weak self] in self?.close() }
        model.reload()

        positionOverParent()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Centre the panel on the terminal it will open a tab in, falling back to
    /// the screen when there isn't one.
    private func positionOverParent() {
        guard let window else { return }
        let anchor = model.parentWindow?.frame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        guard anchor != .zero else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2 + anchor.height * 0.1))
    }

    func windowDidResignKey(_ notification: Foundation.Notification) {
        // Clicking away is a way of saying "never mind".
        close()
    }
}

/// What the picker shows, and what happens when something is chosen.
@MainActor
final class PickerModel: ObservableObject {
    @Published var query: String = ""
    @Published var selection: UUID?
    @Published private(set) var connections: [SSHConnection] = []

    var parentWindow: NSWindow?
    var onDismiss: (() -> Void)?

    /// Connections matching the query, most recently used first.
    var matches: [SSHConnection] {
        connections
            .filter(\.isValid)
            .filter { $0.matches(query: query) }
    }

    func reload() {
        query = ""
        connections = SSHConnectionStore.shared.connections.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default:
                return lhs.displayName.localizedStandardCompare(rhs.displayName)
                    == .orderedAscending
            }
        }
        selection = matches.first?.id
    }

    /// Open `connection` in a new tab and dismiss.
    func open(_ connection: SSHConnection) {
        // Dismiss first so the panel isn't holding key focus when the new tab
        // appears and tries to take it.
        onDismiss?()
        SSHTerminalLauncher.connect(connection, parentWindow: parentWindow)
    }

    func openSelected() {
        guard let selection,
              let connection = matches.first(where: { $0.id == selection })
        else { return }
        open(connection)
    }

    /// Move the highlight, wrapping at both ends.
    func moveSelection(by delta: Int) {
        let list = matches
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.id == selection } ?? 0
        let next = (current + delta + list.count) % list.count
        selection = list[next].id
    }

    /// Keep the highlight on something that is still on screen as the query
    /// narrows the list.
    func clampSelection() {
        let list = matches
        if selection == nil || !list.contains(where: { $0.id == selection }) {
            selection = list.first?.id
        }
    }
}

struct SSHConnectionPickerView: View {
    @ObservedObject var model: PickerModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(OttyTheme.divider)
            list
        }
        .background(OttyTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(OttyTheme.secondaryText)

            TextField("Connect to…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(OttyTheme.primaryText)
                .focused($searchFocused)
                .onSubmit { model.openSelected() }
                .onChange(of: model.query) { _ in model.clampSelection() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        // Arrow keys steer the list while the field keeps the text cursor.
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { model.onDismiss?() }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.matches.isEmpty {
                        Text(model.connections.isEmpty
                             ? "No saved connections"
                             : "Nothing matches “\(model.query)”")
                            .font(OttyTheme.body)
                            .foregroundStyle(OttyTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(model.matches) { connection in
                            row(connection).id(connection.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selection) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func row(_ connection: SSHConnection) -> some View {
        let selected = connection.id == model.selection
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayName)
                    .font(OttyTheme.body)
                    .foregroundStyle(OttyTheme.primaryText)
                    .lineLimit(1)
                Text(connection.subtitle)
                    .font(OttyTheme.detail)
                    .foregroundStyle(OttyTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if connection.groupName != SSHConnection.ungroupedName {
                Text(connection.groupName)
                    .font(OttyTheme.detail)
                    .foregroundStyle(OttyTheme.secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(OttyTheme.hover)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? OttyTheme.selection : .clear)
        .clipShape(RoundedRectangle(cornerRadius: OttyTheme.rowCornerRadius))
        .contentShape(Rectangle())
        .onTapGesture { model.open(connection) }
        .onHover { if $0 { model.selection = connection.id } }
    }
}
