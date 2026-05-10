import Foundation
import Darwin

public struct InterfaceInfo: Sendable, Hashable {
    public let name: String
    public let address: String
    public let broadcast: String
}

public enum NetworkInterfaces {
    /// Returns one entry per UP, non-loopback IPv4 interface that has the
    /// BROADCAST flag set, with that interface's broadcast address. This is
    /// what we point UDP discovery packets at — limited broadcast
    /// (255.255.255.255) is unreliable across Wi-Fi APs and bridges.
    public static func ipv4Broadcasts() -> [InterfaceInfo] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let head = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var results: [InterfaceInfo] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }

            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_BROADCAST != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }

            guard let addrPtr = cur.pointee.ifa_addr,
                  addrPtr.pointee.sa_family == sa_family_t(AF_INET),
                  let bcastPtr = cur.pointee.ifa_dstaddr,
                  bcastPtr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }

            let name = String(cString: cur.pointee.ifa_name)
            guard let addr = sockaddrToString(addrPtr),
                  let bcast = sockaddrToString(bcastPtr) else { continue }
            // Skip APIPA / link-local (169.254/16); not useful for KDE Connect.
            if addr.hasPrefix("169.254.") { continue }
            results.append(InterfaceInfo(name: name, address: addr, broadcast: bcast))
        }
        return results
    }

    private static func sockaddrToString(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard r == 0 else { return nil }
        return String(cString: host)
    }
}
