// InterfaceWatcher.swift — tells the mesh when the Mac's network interfaces
// change (G3.3b): Wi-Fi joins a network, Ethernet is plugged in, an address
// goes away.
//
// It watches the System Configuration dynamic store's IPv4 state of every
// interface. It only watches: no TAK traffic goes through
// SystemConfiguration, so the one-TLS-stack rule (dev/g3/NOTES.md §G3.2)
// holds.

import Foundation
import SystemConfiguration

public final class InterfaceWatcher {
    private var store: SCDynamicStore?
    private let changed: @MainActor () -> Void

    /// Calls `changed` on the main thread after each change.
    public init(changed: @escaping @MainActor () -> Void) {
        self.changed = changed
    }

    public func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<InterfaceWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        guard let store = SCDynamicStoreCreate(nil, "macTAK mesh" as CFString, callback, &context) else { return }
        let ipv4 = SCDynamicStoreKeyCreateNetworkInterfaceEntity(
            nil, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4)
        SCDynamicStoreSetNotificationKeys(store, nil, [ipv4] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        self.store = store
    }

    public func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    deinit { stop() }
}
