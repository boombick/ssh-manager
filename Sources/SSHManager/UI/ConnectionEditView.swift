import SwiftUI

struct ConnectionEditView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Connection
    @State private var identityText: String
    @State private var remoteHostText: String
    @State private var remotePortText: String
    @State private var extraOptionsText: String
    @State private var httpProxyPortText: String

    let title: String
    let onSave: (Connection) -> Void

    init(initial: Connection, title: String, onSave: @escaping (Connection) -> Void) {
        self._draft = State(initialValue: initial)
        self._identityText = State(initialValue: initial.identityFile ?? "")
        self._remoteHostText = State(initialValue: initial.remoteHost ?? "")
        self._remotePortText = State(initialValue: initial.remotePort.map(String.init) ?? "")
        self._extraOptionsText = State(initialValue: initial.extraOptions.joined(separator: "\n"))
        self._httpProxyPortText = State(initialValue: initial.httpProxyPort.map(String.init) ?? "")
        self.title = title
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 16)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)

            Form {
                Section("Basic") {
                    TextField("Name", text: $draft.name)
                    Picker("Type", selection: $draft.type) {
                        ForEach(TunnelType.allCases, id: \.self) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                }

                Section("SSH Target") {
                    TextField("Host", text: $draft.host)
                    TextField("SSH port", value: $draft.sshPort, format: .number)
                    TextField("User", text: $draft.user)
                    TextField("Identity file (optional, ~ supported)", text: $identityText)
                        .help("Leave blank to use ssh's default key search and ssh-agent")
                }

                Section(forwardingSectionTitle) {
                    TextField("Local listen port", value: $draft.listenPort, format: .number)
                    if draft.type != .dynamic {
                        TextField("Remote host", text: $remoteHostText)
                        TextField("Remote port", text: $remotePortText)
                    }
                    if draft.type == .dynamic {
                        Toggle("Enable HTTP proxy", isOn: $draft.httpProxyEnabled)
                        if draft.httpProxyEnabled {
                            TextField("HTTP port (leave blank for auto)", text: $httpProxyPortText)
                        }
                    }
                }

                Section("Behavior") {
                    Toggle("Auto-start on app launch", isOn: $draft.autoStart)
                    Toggle("Auto-reconnect on drop", isOn: $draft.autoReconnect)
                        .help("Reserved for a later phase. Currently has no effect.")
                }

                Section("Extra ssh -o options") {
                    TextEditor(text: $extraOptionsText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                        .help("One option per line, e.g.\nCompression=yes\nTCPKeepAlive=yes")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    commit()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil)
            }
            .padding(12)
        }
        .frame(width: 520, height: 620)
    }

    private var forwardingSectionTitle: String {
        switch draft.type {
        case .dynamic: return "Forwarding (SOCKS)"
        case .local:   return "Forwarding (Local → Remote)"
        case .remote:  return "Forwarding (Local → exposed Remote)"
        }
    }

    private var validationError: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if draft.host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host is required" }
        if draft.user.trimmingCharacters(in: .whitespaces).isEmpty { return "User is required" }
        if !(1...65535).contains(draft.sshPort) { return "SSH port must be 1–65535" }
        if !(1...65535).contains(draft.listenPort) { return "Listen port must be 1–65535" }
        if draft.type != .dynamic {
            if remoteHostText.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Remote host is required"
            }
            guard let p = Int(remotePortText.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(p) else {
                return "Remote port must be 1–65535"
            }
        }
        if draft.type == .dynamic, draft.httpProxyEnabled {
            let trimmed = httpProxyPortText.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                guard let p = Int(trimmed), (1...65535).contains(p) else {
                    return "HTTP port must be 1–65535"
                }
                if p == draft.listenPort {
                    return "HTTP port must differ from SOCKS port"
                }
                if p == draft.listenPort + 10000 {
                    return "HTTP port conflicts with the internal ssh port (listen port + 10000)"
                }
            }
        }
        return nil
    }

    private func commit() {
        var c = draft
        c.identityFile = identityText.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : identityText.trimmingCharacters(in: .whitespaces)
        if draft.type == .dynamic {
            c.remoteHost = nil
            c.remotePort = nil
        } else {
            c.remoteHost = remoteHostText.trimmingCharacters(in: .whitespaces)
            c.remotePort = Int(remotePortText.trimmingCharacters(in: .whitespaces))
        }
        // HTTP proxy fields are only meaningful for .dynamic; nuke them otherwise.
        if draft.type != .dynamic {
            c.httpProxyEnabled = false
            c.httpProxyPort = nil
        } else if c.httpProxyEnabled {
            let trimmed = httpProxyPortText.trimmingCharacters(in: .whitespaces)
            c.httpProxyPort = trimmed.isEmpty ? nil : Int(trimmed)
        } else {
            c.httpProxyPort = nil
        }
        c.extraOptions = extraOptionsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        onSave(c)
    }
}
