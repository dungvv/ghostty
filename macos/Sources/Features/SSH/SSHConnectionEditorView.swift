import SwiftUI
import AppKit

/// Editor for a single saved connection.
struct SSHConnectionEditorView: View {
    @Binding var connection: SSHConnection

    /// Typed-but-not-yet-saved password. Never persisted as part of the
    /// connection; it only lives until the user hits Save.
    @State private var passwordDraft: String = ""
    @State private var passwordStatus: String?
    @State private var passwordFailed: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                actions
                Divider()
                section("Connection") {
                    labeled("Name") {
                        TextField("My Server", text: $connection.name)
                    }
                    labeled("Host") {
                        TextField("example.com or a ~/.ssh/config alias",
                                  text: $connection.host)
                    }
                    labeled("User") {
                        TextField("Defaults to your ssh config",
                                  text: optional($connection.username))
                    }
                    labeled("Port") {
                        TextField("22", text: portBinding)
                            .frame(width: 90)
                    }
                    labeled("Group") {
                        TextField("Ungrouped", text: $connection.group)
                    }
                    Text("The group is the heading this connection appears "
                         + "under in the terminal window's SSH sidebar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Authentication") {
                    labeled("Identity File") {
                        HStack(spacing: 6) {
                            TextField("~/.ssh/id_ed25519",
                                      text: optional($connection.identityFile))
                            Button("Choose…") { chooseIdentityFile() }
                        }
                    }
                    labeled("Jump Host") {
                        TextField("bastion.example.com",
                                  text: optional($connection.proxyJump))
                    }
                    labeled("Password") {
                        passwordField
                    }
                    if let passwordStatus {
                        labeled("") {
                            Text(passwordStatus)
                                .font(.caption)
                                .foregroundStyle(passwordFailed ? Color.red : Color.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("A saved password is kept in your login keychain, never in "
                         + "the connection file. Ghostty hands it to ssh through its "
                         + "askpass hook, so it is also used for a key file's "
                         + "passphrase. Leave this empty to let ssh ask you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("File Browser") {
                    labeled("Remote Path") {
                        TextField("Remote home directory",
                                  text: optional($connection.remotePath))
                    }
                    labeled("Local Path") {
                        HStack(spacing: 6) {
                            TextField("Your home directory",
                                      text: optional($connection.localPath))
                            Button("Choose…") { chooseLocalPath() }
                        }
                    }
                }

                section("Advanced") {
                    labeled("Extra ssh Flags") {
                        TextField("-o Compression=yes", text: extraArgumentsBinding)
                            .font(.system(.body, design: .monospaced))
                    }
                    labeled("Tags") {
                        TextField("work, staging", text: tagsBinding)
                    }
                    Toggle("Use `ghostty +ssh` for terminal sessions",
                           isOn: $connection.useGhosttyWrapper)
                    Text("Installs Ghostty's terminfo on the remote host and forwards "
                         + "Ghostty's environment variables.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    labeled("Notes") {
                        TextEditor(text: $connection.notes)
                            .font(.body)
                            .frame(minHeight: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3)))
                    }
                }

                section("Command") {
                    Text(connection.terminalCommand(
                        ghosttyExecutable: SSHTerminalLauncher.ghosttyExecutable))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(16)
        }
    }

    // MARK: - Pieces

    private var passwordField: some View {
        HStack(spacing: 6) {
            SecureField(connection.usesStoredPassword ? "Saved" : "Not saved",
                        text: $passwordDraft)
                .onSubmit { savePassword() }
            Button("Save") { savePassword() }
                .disabled(passwordDraft.isEmpty)
            if connection.usesStoredPassword {
                Button("Remove") { removePassword() }
            }
        }
    }

    private func savePassword() {
        let secret = passwordDraft
        guard !secret.isEmpty else { return }
        do {
            try SSHCredentialStore.setPassword(
                secret, for: connection.id, label: connection.displayName)
            connection.usesStoredPassword = true
            passwordDraft = ""
            passwordFailed = false
            passwordStatus = "Saved to your login keychain."
        } catch {
            passwordFailed = true
            passwordStatus = error.localizedDescription
        }
    }

    private func removePassword() {
        SSHCredentialStore.removePassword(for: connection.id)
        connection.usesStoredPassword = false
        passwordDraft = ""
        passwordFailed = false
        passwordStatus = "Removed. ssh will ask you from now on."
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                SSHTerminalLauncher.connect(connection)
            } label: {
                Label("Open Terminal", systemImage: "terminal")
            }
            .disabled(!connection.isValid)

            Button {
                FileBrowserController.show(for: connection)
            } label: {
                Label("Browse Files", systemImage: "folder")
            }
            .disabled(!connection.isValid)

            Spacer()

            if !connection.isValid {
                Label("A host is required", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func labeled<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Bindings

    /// Treat an empty text field as "not set" so we don't pass empty flags.
    private func optional(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                source.wrappedValue = trimmed.isEmpty ? nil : newValue
            })
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { connection.port.map(String.init) ?? "" },
            set: { connection.port = Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    private var extraArgumentsBinding: Binding<String> {
        Binding(
            get: { ShellWords.join(connection.extraArguments) },
            set: { connection.extraArguments = ShellWords.split($0) })
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { connection.tags.joined(separator: ", ") },
            set: { newValue in
                connection.tags = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    // MARK: - Panels

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(
            fileURLWithPath: ("~/.ssh" as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            connection.identityFile = url.path
        }
    }

    private func chooseLocalPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            connection.localPath = url.path
        }
    }
}
