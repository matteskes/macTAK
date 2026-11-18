// NetworkInterfaces.swift — the network interfaces a mesh runs on (G3.3).
//
// ATAK opens its mesh inputs and outputs on every interface it finds
// (CommsMapComponent.getInterfaceNames). On a Mac that means the interfaces
// that are up, can multicast, carry IPv4 and reach a local network: not
// loopback, not point-to-point (VPN tunnels), and not Apple's peer-to-peer
// links (AWDL and its low-latency companion), which carry AirDrop, not TAK.

import Darwin

public enum NetworkInterfaces {
    /// The names of the interfaces a mesh should use, sorted.
    public static func meshCapable() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var names = Set<String>()
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: item.ifa_name)
            if isMeshCapable(name: name, flags: item.ifa_flags) { names.insert(name) }
        }
        return names.sorted()
    }

    /// This Mac's IPv4 address on its first mesh-capable interface, as
    /// ATAK's NetworkUtils.getIP gives it for a chat's __serverdestination;
    /// "0.0.0.0" when it has none (G3.5b).
    public static func primaryIPv4() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return "0.0.0.0" }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  isMeshCapable(name: String(cString: item.ifa_name), flags: item.ifa_flags) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: item.ifa_name), String(cString: host)))
        }
        return found.min { $0.name < $1.name }?.address ?? "0.0.0.0"
    }

    static func isMeshCapable(name: String, flags: UInt32) -> Bool {
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_MULTICAST)
        let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard flags & required == required, flags & excluded == 0 else { return false }
        return !["awdl", "llw", "utun"].contains { name.hasPrefix($0) }
    }
}
