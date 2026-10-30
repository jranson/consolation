import Foundation
import Network

/// Which peers a relay host serves: only addresses on the local network (private IPv4, link-local, loopback, and
/// IPv6 link-local or unique-local). Anything else, including carrier-grade NAT and every public address, is refused.
public nonisolated enum RelayPeerPolicy {
    public static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return isLocal(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address): return isLocal(ipv6: [UInt8](address.rawValue))
        case .name: return false
        @unknown default: return false
        }
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16 and 127/8.
    static func isLocal(ipv4 bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    /// ::1, fe80::/10, fc00::/7, and IPv4-mapped local addresses.
    static func isLocal(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return isLocal(ipv4: Array(bytes[12..<16]))
        }
        return false
    }
}
