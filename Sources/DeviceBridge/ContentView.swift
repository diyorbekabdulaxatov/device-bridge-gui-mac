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
        .frame(minWidth: 540, minHeight: 620)
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

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.deviceInfo?.name ?? "Device Bridge")
                    .font(.title3.bold())
                Text(state.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let info = state.deviceInfo {
                Text(shortID(info.deviceId))
                    .font(.caption)
                    .monospaced()
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    private var nearbySection: some View {
        Section("Nearby devices") {
            if state.peers.isEmpty {
                Text("Searching…").foregroundColor(.secondary)
            } else {
                ForEach(state.peers) { peer in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Text(shortID(peer.deviceId))
                                .font(.caption).monospaced().foregroundColor(.secondary)
                        }
                        Spacer()
                        if isPaired(peer.deviceId) {
                            Text("Paired").font(.caption).foregroundColor(.green)
                        } else {
                            Button("Pair") { state.pair(peer) }
                        }
                    }
                }
            }
        }
    }

    private var pairedSection: some View {
        Section("Paired devices") {
            if state.paired.isEmpty {
                Text("None").foregroundColor(.secondary)
            } else {
                ForEach(state.paired) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(shortID(p.deviceId))
                            .font(.caption).monospaced().foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var transfersSection: some View {
        Group {
            if !state.transfers.isEmpty {
                Section("Transfers") {
                    ForEach(state.transfers) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.name).font(.caption)
                            ProgressView(value: t.fraction)
                        }
                    }
                }
            }
        }
    }

    private var messagesSection: some View {
        Section("Messages") {
            if state.messages.isEmpty {
                Text("No messages").foregroundColor(.secondary)
            } else {
                ForEach(state.messages) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.text)
                        if !m.from.isEmpty {
                            Text("from \(shortID(m.from))")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var historySection: some View {
        Section("Clipboard history") {
            TextField("Search history", text: $historySearch)
                .textFieldStyle(.roundedBorder)
                .onChange(of: historySearch) { _, _ in state.searchHistory(historySearch) }
            if state.history.isEmpty {
                Text("Empty").foregroundColor(.secondary)
            } else {
                ForEach(state.history) { h in
                    Button {
                        state.copyToClipboard(h.text)
                    } label: {
                        Text(h.text)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            }
        }
    }

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
            TextField("Message", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { send() }
            Button("Send", action: send)
                .disabled(messageText.isEmpty || selectedPeerID.isEmpty)
            Button(action: chooseAndSendFile) {
                Image(systemName: "paperclip")
            }
            .help("Send a file")
            .disabled(selectedPeerID.isEmpty)
        }
        .padding(12)
        .onReceive(state.$peers) { _ in autoSelect() }
        .onReceive(state.$paired) { _ in autoSelect() }
        .onAppear { autoSelect() }
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

    private func isPaired(_ id: String) -> Bool {
        state.paired.contains { $0.deviceId == id }
    }

    private func shortID(_ s: String) -> String { String(s.prefix(8)) }
}
