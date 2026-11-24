import Darwin
import Foundation

/// Set SMARTROOM_TRACE=1 to log everything sent to and received from the lights to stderr.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["SMARTROOM_TRACE"] != nil

    static func log(_ text: @autoclosure () -> String) {
        if enabled { FileHandle.standardError.write(Data((text() + "\n").utf8)) }
    }
}

/// A broadcast-capable UDP socket on an ephemeral port.
final class UDPSocket {
    /// Called on a background queue with the sender IP and the payload.
    var onDatagram: ((String, Data) -> Void)?

    private let fd: Int32
    private var source: DispatchSourceRead?

    init?(label: String) {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: label))
        src.setEventHandler { [weak self] in self?.drain() }
        src.resume()
        source = src
    }

    deinit {
        source?.cancel()
        close(fd)
    }

    func send(_ data: Data, to ip: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        data.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &text, socklen_t(INET_ADDRSTRLEN))
            onDatagram?(String(cString: text), Data(buffer[0..<count]))
        }
    }

    /// Broadcast addresses of every active IPv4 interface (e.g. 192.168.1.255).
    static func broadcastAddresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return ["255.255.255.255"] }
        defer { freeifaddrs(list) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let destination = entry.pointee.ifa_dstaddr
            else { continue }
            var broadcast = destination.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &broadcast, &text, socklen_t(INET_ADDRSTRLEN))
            let value = String(cString: text)
            if !value.isEmpty, value != "0.0.0.0", !result.contains(value) {
                result.append(value)
            }
        }
        return result.isEmpty ? ["255.255.255.255"] : result
    }
}
