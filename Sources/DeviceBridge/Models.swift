import Foundation

struct DeviceInfo: Codable {
    let deviceId: String
    let name: String
    let publicKey: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name
        case publicKey = "public_key"
    }
}

struct Peer: Codable, Identifiable, Hashable {
    let deviceId: String
    let name: String
    let addr: String
    let publicKey: String

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name
        case addr
        case publicKey = "public_key"
    }
}

struct PairedPeer: Codable, Identifiable {
    let deviceId: String
    let name: String

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case name
    }
}

struct HistoryEntry: Codable, Identifiable {
    let id: Int64
    let text: String
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let from: String
    let text: String
    let time: Date
}
