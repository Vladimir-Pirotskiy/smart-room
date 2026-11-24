import Foundation

/// Transport for the WiZ local protocol (JSON datagrams on UDP port 38899).
final class WizTransport {
    static let port: UInt16 = 38899

    /// Called on the main queue with the sender IP and the decoded JSON object.
    var onMessage: ((String, [String: Any]) -> Void)?

    private let socket: UDPSocket

    init?() {
        guard let socket = UDPSocket(label: "smartroom.wiz.rx") else { return nil }
        self.socket = socket
        socket.onDatagram = { [weak self] ip, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                Trace.log("<- \(ip) \(object)")
                self?.onMessage?(ip, object)
            }
        }
    }

    func send(_ object: [String: Any], to ip: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        Trace.log("-> \(ip) \(String(decoding: data, as: UTF8.self))")
        socket.send(data, to: ip, port: Self.port)
    }

    func broadcast(_ object: [String: Any]) {
        for address in UDPSocket.broadcastAddresses() {
            send(object, to: address)
        }
    }
}
