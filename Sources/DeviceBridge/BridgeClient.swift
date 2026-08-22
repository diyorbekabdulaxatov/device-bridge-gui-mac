import Foundation
import Darwin

enum BridgeError: LocalizedError {
    case connect(String)
    case send(String)

    var errorDescription: String? {
        switch self {
        case .connect(let s): return "connect: \(s)"
        case .send(let s): return "send: \(s)"
        }
    }
}

/// A client for the device core's Unix-socket IPC protocol. Responses are
/// matched to requests by id; unsolicited events are delivered to
/// `eventHandler` on a background queue.
final class BridgeClient {
    typealias ResponseHandler = (Data?, String?) -> Void

    var eventHandler: ((String, [String: Any]) -> Void)?

    private var socketFd: Int32 = -1
    private var source: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "devicebridge.client.io")
    private var buffer = Data()
    private var nextID: Int64 = 0
    private var pending: [Int64: ResponseHandler] = [:]

    var isConnected: Bool { socketFd >= 0 }

    func connect(to path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeError.connect(errnoText())
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                let bytes = path.utf8CString
                let n = min(bytes.count, 104)
                for i in 0..<n {
                    dest[i] = bytes[i]
                }
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        guard rc == 0 else {
            let msg = errnoText()
            close(fd)
            throw BridgeError.connect(msg)
        }

        socketFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in
            if let s = self, s.socketFd >= 0 {
                close(s.socketFd)
                s.socketFd = -1
            }
        }
        src.resume()
        source = src
    }

    func disconnect() {
        source?.cancel()
        source = nil
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }

    func request(_ method: String, params: [String: Any] = [:], completion: @escaping ResponseHandler) {
        ioQueue.async { [self] in
            nextID += 1
            let id = nextID
            var req: [String: Any] = ["id": id, "method": method]
            if !params.isEmpty {
                req["params"] = params
            }
            guard let data = try? JSONSerialization.data(withJSONObject: req) else {
                completion(nil, "failed to encode request")
                return
            }
            pending[id] = completion
            var out = data
            out.append(0x0A)
            out.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                guard let base = buf.baseAddress else { return }
                _ = Darwin.write(socketFd, base, buf.count)
            }
        }
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }

    private func readAvailable() {
        var tmp = [UInt8](repeating: 0, count: 8192)
        let n = Darwin.read(socketFd, &tmp, tmp.count)
        if n <= 0 { return }
        buffer.append(contentsOf: tmp[0..<n])

        while let idx = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<idx])
            buffer.removeSubrange(...idx)
            process(line)
        }
    }

    private func process(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let idNum = obj["id"] as? NSNumber {
            let id = idNum.int64Value
            guard let handler = pending.removeValue(forKey: id) else { return }
            let err = obj["error"] as? String
            var result: Data?
            if let r = obj["result"] {
                result = try? JSONSerialization.data(withJSONObject: r)
            }
            handler(result, err)
        } else if let ev = obj["event"] as? String {
            let data = (obj["data"] as? [String: Any]) ?? [:]
            eventHandler?(ev, data)
        }
    }
}
