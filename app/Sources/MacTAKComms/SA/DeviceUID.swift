// DeviceUID.swift — this Mac's TAK uid (G3.4b).
//
// ATAK 5.5 names a device "ANDROID-" plus its serial number or Wi-Fi MAC
// (LocationMapComponent._determineBestDeviceUID), keeps it, and never
// copies it with the preferences, so restoring settings on another device
// can't make two clients one. Here (owner's choice, 2026-11-17) it is
// "MACTAK-" plus the Mac's hardware UUID (IOPlatformUUID), kept in a file of
// its own, outside every settings suite: no data package, profile or
// settings copy can write it. A copy of the app run with
// --settings-suite NAME is a second client, so its uid gets "-NAME".

import Foundation
import IOKit

public enum DeviceUID {
    public static let prefix = "MACTAK-"

    /// Where the uid is kept: Application Support/macTAK/device-uid.
    public static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macTAK/device-uid")
    }

    /// The uid kept in `file`, made from the hardware UUID the first time
    /// (a random UUID if the hardware won't say). suite names a second
    /// copy of the app's settings.
    public static func resolve(file: URL = defaultFile, suite: String? = nil,
                               hardware: () -> String? = platformUUID) -> String {
        let kept = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: String
        if let kept, kept.hasPrefix(prefix), kept.count > prefix.count {
            base = kept
        } else {
            base = prefix + (hardware() ?? UUID().uuidString)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (base + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        guard let suite, !suite.isEmpty else { return base }
        return "\(base)-\(suite)"
    }

    /// IOPlatformExpertDevice's IOPlatformUUID.
    public static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }
}
