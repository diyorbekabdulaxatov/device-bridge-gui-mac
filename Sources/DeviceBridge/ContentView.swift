import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var messageText = ""
    @State private var selectedPeerID = ""
    @State private var historySearch = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                nearbySection
                pairedSection
                transfersSection
                messagesSection
                historySection
            }
            .listStyle(.inset)
            Divider()
            sendBar
        }
        .frame(minWidth: 560, minHeight: 640)
        .onAppear { state.start() }
        .onDisappear { state.stop() }
        .alert(item: $state.pendingPair) { request in
            Alert(
                title: Text("Pairing request"),
                message: Text("Allow \"\(request.name)\" to pair with this Mac?"),
                primaryButton: .default(Text("Accept")) { state.respondToPair(accept: true) },
                secondaryButton: .cancel(Text("Reject")) { state.respondToPair(accept: false) }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.deviceInfo?.name ?? "Device Bridge")
                    .font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(state.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let info = state.deviceInfo {
                Text(shortID(info.deviceId))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        if state.status.hasPrefix("Connected") { return .green }
        if state.status.hasPrefix("Disconnected") || state.status.hasPrefix("Failed") { return .red }
        return .orange
    }

    // MARK: - Sections

    private var nearbySection: some View {
        Section {
            if state.peers.isEmpty {
                Text("Searching for devices…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.peers) { peer in
                    deviceRow(peer)
                }
            }
        } header: {
            Label("Nearby Devices", systemImage: "wifi")
        }
    }

    private func deviceRow(_ peer: Peer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).fontWeight(.medium)
                Text(shortID(peer.deviceId))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPaired(peer.deviceId) {
                Label("Paired", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Pair") { state.pair(peer) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var pairedSection: some View {
        Section {
            if state.paired.isEmpty {
                Text("No paired devices yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.paired) { p in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text(p.name)
                        Spacer()
                        Text(shortID(p.deviceId))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Label("Paired Devices", systemImage: "checkmark.shield")
        }
    }

    private var transfersSection: some View {
        Group {
            if !state.transfers.isEmpty {
                Section {
                    ForEach(state.transfers) { t in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                Text(t.name).font(.callout)
                                Spacer()
                                Text("\(t.sent) / \(t.total)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: t.fraction)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }

    private var messagesSection: some View {
        Section {
            if state.messages.isEmpty {
                Text("No messages yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.messages) { m in
                    messageBubble(m)
                }
            }
        } header: {
            Label("Messages", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private func messageBubble(_ m: ChatMessage) -> some View {
        HStack {
            if m.from.isEmpty {
                Spacer(minLength: 48)
                Text(m.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text(m.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 48)
            }
        }
        .padding(.vertical, 2)
    }

    private var historySection: some View {
        Section {
            TextField("Search history", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: historySearch) { _, _ in state.searchHistory(historySearch) }
            if state.history.isEmpty {
                Text("Clipboard history is empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.history) { h in
                    Button {
                        state.copyToClipboard(h.text)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard")
                                .foregroundStyle(.secondary)
                            Text(h.text)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy to clipboard")
                }
            }
        } header: {
            Label("Clipboard History", systemImage: "doc.on.clipboard")
        }
    }

    // MARK: - Send bar

    private var sendBar: some View {
        HStack(spacing: 8) {
            Picker("To", selection: $selectedPeerID) {
                if sendablePeers.isEmpty {
                    Text("No paired device").tag("")
                } else {
                    ForEach(sendablePeers) { peer in
                        Text(peer.name).tag(peer.deviceId)
                    }
                }
            }
            .frame(width: 180)
            .labelsHidden()

            TextField("Message", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }

            Button(action: chooseAndSendFile) {
                Image(systemName: "paperclip")
            }
            .help("Send a file")
            .disabled(selectedPeerID.isEmpty)

            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Send message")
            .disabled(messageText.isEmpty || selectedPeerID.isEmpty)
        }
        .padding(12)
        .onReceive(state.$peers) { _ in autoSelect() }
        .onReceive(state.$paired) { _ in autoSelect() }
        .onAppear { autoSelect() }
    }

    private var sendablePeers: [Peer] {
        state.peers.filter { isPaired($0.deviceId) }
    }

    private func autoSelect() {
        let candidates = sendablePeers
        if selectedPeerID.isEmpty || !candidates.contains(where: { $0.deviceId == selectedPeerID }) {
            selectedPeerID = candidates.first?.deviceId ?? ""
        }
    }

    private func send() {
        guard let peer = state.peers.first(where: { $0.deviceId == selectedPeerID }) else { return }
        state.sendText(messageText, to: peer)
        messageText = ""
    }

    private func chooseAndSendFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let peer = state.peers.first(where: { $0.deviceId == selectedPeerID }) else { return }
        state.sendFile(url.path, to: peer)
    }

    private func isPaired(_ id: String) -> Bool {
        state.paired.contains { $0.deviceId == id }
    }

    private func shortID(_ s: String) -> String { String(s.prefix(8)) }
}
