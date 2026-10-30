import Darwin

/// One IPv4 address of a local network interface, with the math for its subnet-directed broadcast.
///
/// Addresses and masks are held in host byte order, so `192.0.2.10` is `0xC000_020A`.
nonisolated struct IPv4InterfaceAddress: Sendable, Hashable {
    let name: String
    /// The interface index, as `IP_BOUND_IF` expects it.
    let index: UInt32
    let address: UInt32
    let netmask: UInt32

    /// The limited broadcast address, `255.255.255.255`.
    static let limitedBroadcast: UInt32 = 0xFFFF_FFFF

    /// `address | ~netmask`: for `192.0.2.10/24` that is `192.0.2.255`.
    var directedBroadcast: UInt32 { address | ~netmask }

    /// False for /31 and /32 (point-to-point, no broadcast) and for a zero mask.
    var hasDirectedBroadcast: Bool { netmask != 0 && ~netmask > 1 }

    // MARK: Dotted quads

    static func dottedQuad(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Parses `192.0.2.10` into host byte order, or nil when it is not a dotted-quad IPv4 literal.
    static func parse(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard (1...3).contains(octet.count), octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt32(octet), number <= 255 else { return nil }
            value = value << 8 | number
        }
        return value
    }

    // MARK: Interfaces

    /// One entry per interface: its name, index and the directed broadcast of each of its IPv4 addresses.
    struct BroadcastTargets: Sendable, Hashable {
        let name: String
        let index: UInt32
        let broadcasts: [UInt32]
    }

    /// Groups addresses by interface, in first-seen order, dropping those with no directed broadcast and
    /// duplicate broadcast addresses.
    static func broadcastTargets(for addresses: [Self]) -> [BroadcastTargets] {
        var order: [String] = []
        var grouped: [String: (index: UInt32, broadcasts: [UInt32])] = [:]
        for entry in addresses where entry.hasDirectedBroadcast {
            if grouped[entry.name] == nil {
                order.append(entry.name)
                grouped[entry.name] = (entry.index, [])
            }
            if grouped[entry.name]?.broadcasts.contains(entry.directedBroadcast) == false {
                grouped[entry.name]?.broadcasts.append(entry.directedBroadcast)
            }
        }
        return order.compactMap { name in
            grouped[name].map { BroadcastTargets(name: name, index: $0.index, broadcasts: $0.broadcasts) }
        }
    }

    /// The IPv4 addresses of every interface that is up, running, broadcast-capable and not loopback.
    static func current() -> [Self] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        var result: [Self] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = entry.pointee.ifa_flags
            guard flags & required == required, flags & UInt32(IFF_LOOPBACK) == 0,
                  let addressPointer = entry.pointee.ifa_addr, let maskPointer = entry.pointee.ifa_netmask,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let index = if_nametoindex(entry.pointee.ifa_name)
            guard index != 0 else { continue }
            result.append(Self(
                name: name,
                index: index,
                address: hostOrderIPv4(addressPointer),
                netmask: hostOrderIPv4(maskPointer)
            ))
        }
        return result
    }

    /// Reads `sin_addr` byte by byte, honouring `sa_len`: the kernel may trim a netmask's trailing zero bytes.
    private static func hostOrderIPv4(_ pointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        let length = Int(pointer.pointee.sa_len)
        let addressOffset = MemoryLayout.offset(of: \sockaddr_in.sin_addr) ?? 4
        let raw = UnsafeRawPointer(pointer)
        var value: UInt32 = 0
        for byteIndex in 0..<4 {
            let offset = addressOffset + byteIndex
            let byte = offset < length ? raw.load(fromByteOffset: offset, as: UInt8.self) : 0
            value = value << 8 | UInt32(byte)
        }
        return value
    }
}
