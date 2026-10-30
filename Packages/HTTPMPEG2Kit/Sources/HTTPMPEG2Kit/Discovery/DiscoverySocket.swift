import Darwin

/// A non-blocking IPv4 UDP socket that may broadcast, optionally pinned to one interface with `IP_BOUND_IF`.
///
/// Used only inside one discovery run and closed when released. Not `Sendable`: it never leaves the task that
/// created it.
nonisolated final class DiscoverySocket {
    /// The interface the socket is bound to, or nil for the unbound fallback socket.
    let interfaceName: String?
    private let descriptor: Int32
    /// The last socket error, for diagnostics.
    private(set) var lastError: Int32 = 0

    /// Opens the socket, or returns nil with `errno` set when the system refuses.
    init?(interfaceName: String?, interfaceIndex: UInt32?) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        var enabled: Int32 = 1
        var configured = setsockopt(
            descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
        if configured, var index = interfaceIndex {
            configured = setsockopt(
                descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
        }
        if configured {
            let flags = fcntl(descriptor, F_GETFL)
            configured = flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
        }
        guard configured else {
            let saved = errno
            close(descriptor)
            errno = saved
            return nil
        }
        self.descriptor = descriptor
        self.interfaceName = interfaceName
    }

    deinit {
        close(descriptor)
    }

    /// Sends one datagram to `address` (host byte order). Returns false and records `errno` on failure.
    func send(_ packet: [UInt8], to address: UInt32, port: UInt16) -> Bool {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr = in_addr(s_addr: address.bigEndian)
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(descriptor, buffer.baseAddress, buffer.count, 0, socketAddress,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else {
            lastError = errno
            return false
        }
        return true
    }

    /// Reads one waiting datagram into `buffer` without blocking. Returns its length and the sender's IPv4
    /// address (host byte order), or nil when nothing is waiting or the read failed.
    func receive(into buffer: inout [UInt8]) -> (count: Int, sender: UInt32)? {
        var source = sockaddr_in()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    recvfrom(descriptor, bytes.baseAddress, bytes.count, 0, socketAddress, &sourceLength)
                }
            }
        }
        guard count >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK { lastError = errno }
            return nil
        }
        guard source.sin_family == sa_family_t(AF_INET) else { return (count, 0) }
        return (count, UInt32(bigEndian: source.sin_addr.s_addr))
    }
}
