// SelfDetails.swift — who this client says it is, and how often (G3.4b).
//
// The self details persist in the settings store under ATAK 5.5's own
// preference keys, so a data package's or device profile's
// locationCallsign, and later any other ATAK preference, lands where ATAK's
// would. Values are strings, as ATAK keeps them. Read at the pin:
//   locationCallsign, locationTeam (default Cyan, ensureValidGroup on load),
//   atakRoleType (Team Member), customRole, customRoleAbbreviation,
//   customRoleUseTypeIcon, locationUnitType (a-f-G-U-C), userRemarks,
//   locationReportingStrategy and the eight rate keys (ReportingRate).
// The uid is not here: it is the device's (DeviceUID), never a preference.

import Combine
import Foundation

@MainActor
public final class SelfDetails: ObservableObject {
    public let uid: String

    @Published public var callsign: String { didSet { if callsign != oldValue { changed() } } }
    @Published public var team: String { didSet { if team != oldValue { changed() } } }
    @Published public var role: String { didSet { if role != oldValue { changed() } } }
    @Published public var customRole: String { didSet { if customRole != oldValue { changed() } } }
    @Published public var customRoleAbbreviation: String {
        didSet { if customRoleAbbreviation != oldValue { changed() } }
    }
    @Published public var useTypeIcon: Bool { didSet { if useTypeIcon != oldValue { changed() } } }
    @Published public var unitType: String { didSet { if unitType != oldValue { changed() } } }
    @Published public var remarks: String { didSet { if remarks != oldValue { changed() } } }
    @Published public var reporting: ReportingRate.Settings { didSet { if reporting != oldValue { changed() } } }

    /// Called after every change, once it is saved.
    public var onChange: (@MainActor (SelfDetails) -> Void)?

    /// ATAK's roles (RoleSelector, roles/roles.sqlite's defaults).
    public static let roles = ["Team Member", "Team Lead", "HQ", "Sniper", "Medic", "Forward Observer", "RTO", "K9"]

    private let settings: SettingsStore
    private var loading = true

    enum Key {
        static let callsign = "locationCallsign", team = "locationTeam", role = "atakRoleType"
        static let customRole = "customRole", customRoleAbbreviation = "customRoleAbbreviation"
        static let useTypeIcon = "customRoleUseTypeIcon", unitType = "locationUnitType", remarks = "userRemarks"
        static let strategy = "locationReportingStrategy"
        /// G3.2d's placeholder, read once if locationCallsign isn't set.
        static let legacyCallsign = "mactak.callsign"
    }

    public init(settings: SettingsStore, uid: String) {
        self.settings = settings
        self.uid = uid
        func string(_ key: String) -> String? { settings.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 } }
        callsign = string(Key.callsign) ?? string(Key.legacyCallsign) ?? "MACTAK-\(uid.suffix(4).uppercased())"
        team = GroupDetail.validTeam(string(Key.team) ?? GroupDetail.defaultTeam)
        role = string(Key.role) ?? GroupDetail.defaultRole
        customRole = string(Key.customRole) ?? ""
        customRoleAbbreviation = string(Key.customRoleAbbreviation) ?? ""
        useTypeIcon = string(Key.useTypeIcon) == "true"
        unitType = string(Key.unitType) ?? SelfEvent.defaultType
        remarks = string(Key.remarks) ?? ""
        reporting = Self.loadReporting(string)
        loading = false
        save()
    }

    /// The self-SA's identity from these details.
    public func apply(to event: inout SelfEvent) {
        event.callsign = callsign
        event.type = unitType
        event.remarks = remarks.isEmpty ? nil : remarks
        event.group = GroupDetail(team: team, role: role,
                                  customRole: customRole.isEmpty ? nil : customRole,
                                  customRoleAbbreviation: customRoleAbbreviation.isEmpty ? nil : customRoleAbbreviation,
                                  displayAsSymbologyGraphic: useTypeIcon)
    }

    private func changed() {
        guard !loading else { return }
        save()
        onChange?(self)
    }

    private func save() {
        settings.set(callsign, forKey: Key.callsign)
        settings.set(team, forKey: Key.team)
        settings.set(role, forKey: Key.role)
        settings.set(customRole, forKey: Key.customRole)
        settings.set(customRoleAbbreviation, forKey: Key.customRoleAbbreviation)
        settings.set(useTypeIcon ? "true" : "false", forKey: Key.useTypeIcon)
        settings.set(unitType, forKey: Key.unitType)
        settings.set(remarks, forKey: Key.remarks)
        settings.set(reporting.strategy.rawValue, forKey: Key.strategy)
        for (key, path) in Self.rateKeys { settings.set(String(reporting[keyPath: path]), forKey: key) }
    }

    static let rateKeys: [(String, WritableKeyPath<ReportingRate.Settings, Int>)] = [
        ("constantReportingRateUnreliable", \.constantUnreliable),
        ("constantReportingRateReliable", \.constantReliable),
        ("dynamicReportingRateStationaryUnreliable", \.dynamicStationaryUnreliable),
        ("dynamicReportingRateMinUnreliable", \.dynamicMinUnreliable),
        ("dynamicReportingRateMaxUnreliable", \.dynamicMaxUnreliable),
        ("dynamicReportingRateStationaryReliable", \.dynamicStationaryReliable),
        ("dynamicReportingRateMinReliable", \.dynamicMinReliable),
        ("dynamicReportingRateMaxReliable", \.dynamicMaxReliable),
    ]

    /// ATAK falls back to the default for a rate that isn't a number or is
    /// negative; so does this.
    private static func loadReporting(_ string: (String) -> String?) -> ReportingRate.Settings {
        var r = ReportingRate.Settings.atak
        r.strategy = string(Key.strategy).flatMap(ReportingRate.Strategy.init(rawValue:)) ?? .dynamic
        for (key, path) in rateKeys {
            if let value = string(key).flatMap(Int.init), value >= 0 { r[keyPath: path] = value }
        }
        return r
    }
}
