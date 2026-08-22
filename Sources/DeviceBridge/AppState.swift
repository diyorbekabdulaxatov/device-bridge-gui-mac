import Foundation
import AppKit

@MainActor
final class AppState: ObservableObject {
    @Published var status: String = "Not started"
    @Published var deviceInfo: DeviceInfo?
    @Published var peers: [Peer] = []
    @Published var paired: [PairedPeer] = []
    @Published var messages: [ChatMessage] = []
    @Published var history: [HistoryEntry] = []
    @Published var pendingPair: PairRequest?
    @Published var transfers: [TransferProgress] = []

    private let client = BridgeClient()
    private var helper: Process?
    private var socketPath = ""
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        status = "Launching helper…"

        let name = Host.current().localizedName ?? "Mac"
        let dataDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeviceBridge", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        let receiveDir = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DeviceBridge", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: receiveDir, withIntermediateDirectories: true)

        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("devicebridge-\(UUID().uuidString).sock").path

        let p = Process()
        p.executableURL = URL(fileURLWithPath: locateHelperBinary())
        p.arguments = ["-name", name, "-dir", dataDir, "-ipc", socketPath, "-receive-dir", receiveDir, "-clipboard"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            status = "Failed to launch helper: \(error.localizedDescription). Build the Go core and set DEVICE_BRIDGE_BIN or add 'bridge' to PATH."
            return
        }
        helper = p

        client.eventHandler = { [weak self] event, data in
            DispatchQueue.main.async { self?.handle(event: event, data: data) }
        }
        client.onDisconnect = { [weak self] in
            DispatchQueue.main.async { self?.handleDisconnect() }
        }

        connectWithRetry()
    }

    func stop() {
        helper?.terminate()
        helper = nil
        client.disconnect()
    }

    func pair(_ peer: Peer) {
        client.request("pair", params: ["device_id": peer.deviceId, "addr": peer.addr, "key": peer.publicKey]) { _, err in
            DispatchQueue.main.async {
                if let err {
                    self.status = "Pair failed: \(err)"
                } else {
                    self.status = "Paired with \(peer.name)"
                    self.refreshPaired()
                }
            }
        }
    }

    func sendText(_ text: String, to peer: Peer) {
        client.request("send_text", params: ["device_id": peer.deviceId, "addr": peer.addr, "text": text]) { _, err in
            DispatchQueue.main.async {
                if let err { self.status = "Send failed: \(err)" }
            }
        }
    }

    func sendFile(_ path: String, to peer: Peer) {
        let name = (path as NSString).lastPathComponent
        client.request("send_file", params: ["device_id": peer.deviceId, "addr": peer.addr, "path": path]) { result, err in
            DispatchQueue.main.async {
                if let err {
                    self.status = "Send file failed: \(err)"
                } else {
                    let sent = self.sentBytes(from: result)
                    self.status = "Sent \(name) to \(peer.name)"
                    self.messages.append(ChatMessage(from: "", text: "Sent \(name) (\(sent) bytes)", time: Date()))
                }
            }
        }
    }

    private func sentBytes(from result: Data?) -> String {
        guard let result,
              let obj = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
              let sent = obj["sent"] as? NSNumber else { return "?" }
        return "\(sent.int64Value)"
    }

    func respondToPair(accept: Bool) {
        guard let p = pendingPair else { return }
        client.request("pair_respond", params: ["device_id": p.deviceId, "accept": accept]) { _, _ in
            DispatchQueue.main.async {
                if accept {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.refreshPaired()
                    }
                }
            }
        }
        pendingPair = nil
    }

    func refreshPeers() {
        request("list_peers", as: [Peer].self) { [weak self] in self?.peers = $0 ?? [] }
    }

    func refreshPaired() {
        request("list_paired", as: [PairedPeer].self) { [weak self] in self?.paired = $0 ?? [] }
    }

    func refreshHistory() {
        request("history_list", params: ["limit": 50], as: [HistoryEntry].self) { [weak self] in self?.history = $0 ?? [] }
    }

    func searchHistory(_ query: String) {
        if query.isEmpty {
            refreshHistory()
            return
        }
        request("history_search", params: ["query": query, "limit": 50], as: [HistoryEntry].self) { [weak self] in self?.history = $0 ?? [] }
    }

    func copyToClipboard(_ text: String) {
        client.request("set_clipboard", params: ["text": text]) { _, err in
            DispatchQueue.main.async {
                if let err { self.status = "Copy failed: \(err)" }
            }
        }
    }

    // MARK: - Internals

    private func request<T: Decodable>(_ method: String, params: [String: Any] = [:], as type: T.Type, completion: @escaping (T?) -> Void) {
        client.request(method, params: params) { resultData, _ in
            guard let resultData else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let decoded = try? JSONDecoder().decode(T.self, from: resultData)
            DispatchQueue.main.async { completion(decoded) }
        }
    }

    private func connectWithRetry(attempt: Int = 0) {
        do {
            try client.connect(to: socketPath)
            status = "Connected"
            loadInitial()
        } catch {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.connectWithRetry(attempt: attempt + 1)
                }
            } else {
                status = "Failed to connect: \(error.localizedDescription)"
            }
        }
    }

    private func loadInitial() {
        request("device_info", as: DeviceInfo.self) { [weak self] in self?.deviceInfo = $0 }
        refreshPeers()
        refreshPaired()
        refreshHistory()
    }

    private func locateHelperBinary() -> String {
        // 1. Explicit override.
        if let env = ProcessInfo.processInfo.environment["DEVICE_BRIDGE_BIN"], !env.isEmpty {
            return env
        }
        // 2. Next to the running executable (covers app bundles and build dirs).
        let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let exeDir = (exePath as NSString).deletingLastPathComponent
        let sibling = (exeDir as NSString).appendingPathComponent("bridge")
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }
        // 3. On PATH.
        if let path = which("bridge") {
            return path
        }
        // 4. Common development location.
        let dev = ("~/Desktop/android-mac-bridge/device_bridge_backend/bridge" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: dev) {
            return dev
        }
        return "bridge"
    }

    private func which(_ cmd: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [cmd]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty ?? true) ? nil : out
    }

    private func handleDisconnect() {
        guard started else { return }
        status = "Disconnected — helper stopped"
        peers = []
    }

    private func handle(event: String, data: [String: Any]) {        switch event {
        case "peer_discovered":
            guard let id = data["device_id"] as? String else { return }
            let name = data["name"] as? String ?? ""
            let addr = data["addr"] as? String ?? ""
            let key = data["public_key"] as? String ?? ""
            let peer = Peer(deviceId: id, name: name, addr: addr, publicKey: key)
            if !peers.contains(where: { $0.deviceId == id }) {
                peers.append(peer)
            }
        case "pair_request":
            let name = data["name"] as? String ?? ""
            let id = data["device_id"] as? String ?? ""
            status = "Incoming pair request from \(name)"
            pendingPair = PairRequest(deviceId: id, name: name)
        case "message_received":
            let from = data["from"] as? String ?? ""
            let text = data["text"] as? String ?? ""
            messages.append(ChatMessage(from: from, text: text, time: Date()))
            refreshHistory()
        case "file_received":
            let name = data["name"] as? String ?? ""
            let path = data["path"] as? String ?? ""
            status = "Received file \(name)"
            messages.append(ChatMessage(from: "", text: "Received file \(name) at \(path)", time: Date()))
            refreshHistory()
        case "file_progress":
            let name = data["name"] as? String ?? ""
            let sent = (data["sent"] as? NSNumber)?.int64Value ?? 0
            let total = (data["total"] as? NSNumber)?.int64Value ?? 0
            updateTransfer(name: name, sent: sent, total: total)
        case "clipboard_updated":
            refreshHistory()
        default:
            break
        }
    }

    private func updateTransfer(name: String, sent: Int64, total: Int64) {
        let item = TransferProgress(name: name, sent: sent, total: total)
        if let idx = transfers.firstIndex(where: { $0.name == name }) {
            transfers[idx] = item
        } else {
            transfers.append(item)
        }
        if sent >= total {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.transfers.removeAll { $0.name == name }
            }
        }
    }
}
