import AppKit
import SwiftUI

/// The right panel: what the focused tab is doing.
///
/// Working directory, the process running in it, and any TCP ports that
/// process or its children are listening on.
struct TerminalInfoPanel: View {
    /// The focused surface.
    ///
    /// Observed directly rather than taking a pwd and a pid as plain values,
    /// because both change while the panel is open — `cd` moves the working
    /// directory, and running a command changes the foreground process — and
    /// only observing the surface redraws when they do.
    var surface: Ghostty.SurfaceView?

    /// Space to leave at the top for the traffic lights when the window has no
    /// titlebar of its own.
    var topInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let surface {
                TerminalInfoContent(surface: surface)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    section("Working Directory") { empty("—") }
                    section("Process") { empty("No terminal focused") }
                }
                .padding(.horizontal, OttyTheme.panelPadding + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OttyTheme.panel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
            Text("Info")
                .font(OttyTheme.heading)

            Spacer()
        }
        .foregroundStyle(OttyTheme.headingText)
        .padding(.top, topInset)
        .padding(.horizontal, OttyTheme.panelPadding + 4)
        .padding(.bottom, 14)
    }
}

/// The panel's body once there is a surface to describe.
///
/// Split out so `surface` can be an `@ObservedObject`, which it can't be
/// while it is optional.
private struct TerminalInfoContent: View {
    @ObservedObject var surface: Ghostty.SurfaceView

    @StateObject private var model = InfoModel()

    private var pwd: URL? {
        guard let pwd = surface.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd)
    }

    private var pid: pid_t? {
        guard let pid = surface.surfaceModel?.foregroundPID else { return nil }
        return pid_t(pid)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                workingDirectory
                process
                ports
            }
            .padding(.horizontal, OttyTheme.panelPadding + 4)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: pid) { await model.track(pid: pid) }
    }

    // MARK: - Sections

    private var workingDirectory: some View {
        section("Working Directory") {
            Text(displayPath)
                .font(OttyTheme.body)
                .foregroundStyle(OttyTheme.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            if let pwd {
                VStack(alignment: .leading, spacing: 7) {
                    link("Copy Path", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pwd.path, forType: .string)
                    }
                    link("Reveal in Finder", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([pwd])
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var process: some View {
        section("Process") {
            if let info = model.process {
                HStack(spacing: 7) {
                    Circle()
                        .fill(info.running ? OttyTheme.running : OttyTheme.stopped)
                        .frame(width: 7, height: 7)
                    Text(info.name)
                        .font(OttyTheme.body)
                        .foregroundStyle(OttyTheme.primaryText)
                    Text(verbatim: String(info.pid))
                        .font(OttyTheme.number)
                        .foregroundStyle(OttyTheme.secondaryText)
                    Spacer(minLength: 8)
                    Text(info.uptime)
                        .font(OttyTheme.number)
                        .foregroundStyle(OttyTheme.secondaryText)
                }
            } else {
                empty("No process")
            }
        }
    }

    private var ports: some View {
        section("Ports") {
            if model.ports.isEmpty {
                empty(model.portsLoaded ? "No listening ports" : "Checking…")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.ports) { port in
                        HStack(spacing: 7) {
                            Text(verbatim: String(port.port))
                                .font(OttyTheme.number)
                                .foregroundStyle(OttyTheme.primaryText)
                            Text(port.process)
                                .font(OttyTheme.detail)
                                .foregroundStyle(OttyTheme.secondaryText)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                NSWorkspace.shared.open(
                                    URL(string: "http://localhost:\(port.port)")!)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(OttyTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Open http://localhost:\(port.port)")
                        }
                    }
                }
            }
        }
    }


    /// Paths under home read better as `~/…`, which is also how the terminal
    /// prompt shows them.
    private var displayPath: String {
        guard let pwd else { return "—" }
        return (pwd.path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - Shared pieces

@ViewBuilder
private func section<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title)
            .font(OttyTheme.heading)
            .foregroundStyle(OttyTheme.headingText)
        content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
}

@ViewBuilder
private func link(
    _ title: String,
    icon: String,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(OttyTheme.body)
        }
        .foregroundStyle(OttyTheme.accent)
    }
    .buttonStyle(.plain)
}

@ViewBuilder
private func empty(_ text: String) -> some View {
    Text(text)
        .font(OttyTheme.body)
        .foregroundStyle(OttyTheme.secondaryText)
}

/// Polls the facts the panel shows.
///
/// Process identity and uptime come from the kernel and are cheap, so they
/// tick every second. Ports need `lsof`, so they refresh far less often.
@MainActor
private final class InfoModel: ObservableObject {
    struct Process: Equatable {
        let pid: pid_t
        let name: String
        let running: Bool
        let uptime: String
    }

    @Published private(set) var process: Process?
    @Published private(set) var ports: [ProcessProbe.Port] = []
    @Published private(set) var portsLoaded = false

    private static let portInterval: TimeInterval = 5

    /// Follow `pid` until the task is cancelled, which `task(id:)` does for us
    /// whenever the focused tab changes.
    func track(pid: pid_t?) async {
        process = nil
        ports = []
        portsLoaded = false

        guard let pid else { return }

        var lastPortCheck = Date.distantPast
        while !Task.isCancelled {
            let alive = ProcessProbe.isAlive(pid: pid)
            let start = ProcessProbe.startTime(pid: pid)
            process = Process(
                pid: pid,
                name: TerminalTabsModel.processName(pid: pid) ?? "unknown",
                running: alive,
                uptime: start.map {
                    ProcessProbe.formatDuration(Date().timeIntervalSince($0))
                } ?? "")

            if alive, Date().timeIntervalSince(lastPortCheck) >= Self.portInterval {
                lastPortCheck = Date()
                let found = await ProcessProbe.listeningPorts(under: pid)
                if Task.isCancelled { return }
                ports = found
                portsLoaded = true
            }

            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        }
    }
}
