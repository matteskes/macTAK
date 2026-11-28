// SADetails.swift — typed views of the details a self-SA carries (G3.4).
//
// Each reads and writes one element the way ATAK 5.5 does:
//   __group            the kernel's gov.tak.api.cot.detail.GroupDetailHandler
//                      (5.5's extended roles: exrole, abbr, typeicon)
//   precisionlocation  the app's PrecisionLocationHandler
//   contact, uid, takv, status, track, remarks
//                      CotMapComponent.getSelfEvent and the app's handlers.

public struct GroupDetail: Sendable, Equatable {
    public static let elementName = "__group"
    public static let defaultRole = "Team Member"
    /// The `locationTeam` preference's default, as 5.5 reads it
    /// (LocationMapComponent, ChatManagerMapComponent).
    public static let defaultTeam = "Cyan"
    /// The teams ATAK knows (GroupDetailHandler.ensureValidGroup).
    public static let teams = ["White", "Yellow", "Orange", "Magenta", "Red", "Maroon", "Purple",
                               "Dark Blue", "Blue", "Cyan", "Teal", "Green", "Dark Green", "Brown"]

    public var team: String?
    public var role: String
    public var customRole: String?
    public var customRoleAbbreviation: String?
    public var displayAsSymbologyGraphic: Bool

    public init(team: String?, role: String = defaultRole, customRole: String? = nil,
                customRoleAbbreviation: String? = nil, displayAsSymbologyGraphic: Bool = false) {
        self.team = team; self.role = role
        self.customRole = customRole; self.customRoleAbbreviation = customRoleAbbreviation
        self.displayAsSymbologyGraphic = displayAsSymbologyGraphic
    }

    /// GroupDetailHandler.toItemMetadata: an unknown team reads as Pink, which
    /// ATAK uses to show that the name was wrong. Empty values are absent.
    public init?(_ detail: CotDetail?) {
        guard let detail, detail.name == Self.elementName else { return nil }
        func value(_ key: String) -> String? { detail[key].flatMap { $0.isEmpty ? nil : $0 } }
        self.init(team: value("name").map(Self.validTeam),
                  role: value("role") ?? Self.defaultRole,
                  customRole: value("exrole"),
                  customRoleAbbreviation: value("abbr"),
                  displayAsSymbologyGraphic: value("typeicon").map { $0.lowercased() == "true" } ?? false)
    }

    public static func validTeam(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "rad sensor" { return "Yellow" }
        return teams.first { $0.lowercased() == lower } ?? "Pink"
    }

    /// GroupDetailHandler.toCotDetail(AttributeSet).
    public var detail: CotDetail {
        var d = CotDetail(Self.elementName)
        d["name"] = team
        d["role"] = role
        d["exrole"] = customRole
        d["abbr"] = customRoleAbbreviation
        if displayAsSymbologyGraphic { d["typeicon"] = "true" }
        return d
    }
}

/// <precisionlocation>: where the point and its altitude came from.
public struct PrecisionLocation: Sendable, Equatable {
    public static let elementName = "precisionlocation"
    /// GeoPointMetaData's sources.
    public static let gps = "GPS", user = "USER", unknown = "???"

    public var geopointSource: String?
    public var altitudeSource: String?

    public init(geopointSource: String?, altitudeSource: String?) {
        self.geopointSource = geopointSource; self.altitudeSource = altitudeSource
    }

    public init?(_ detail: CotDetail?) {
        guard let detail, detail.name == Self.elementName else { return nil }
        self.init(geopointSource: detail["geopointsrc"], altitudeSource: detail["altsrc"])
    }

    /// nil when there is nothing to say, as PrecisionLocationHandler writes
    /// no element then.
    public var detail: CotDetail? {
        guard geopointSource != nil || altitudeSource != nil else { return nil }
        var d = CotDetail(Self.elementName)
        d["geopointsrc"] = geopointSource
        d["altsrc"] = altitudeSource
        return d
    }
}

/// <takv>: the sending client.
public struct TakVersion: Sendable, Equatable {
    public var device: String
    public var platform: String
    public var os: String
    public var version: String

    public init(device: String, platform: String, os: String, version: String) {
        self.device = device; self.platform = platform; self.os = os; self.version = version
    }

    public init?(_ detail: CotDetail?) {
        guard let detail, detail.name == "takv" else { return nil }
        self.init(device: detail["device"] ?? "", platform: detail["platform"] ?? "",
                  os: detail["os"] ?? "", version: detail["version"] ?? "")
    }

    public var detail: CotDetail {
        var d = CotDetail("takv")
        d["device"] = device; d["platform"] = platform; d["os"] = os; d["version"] = version
        return d
    }
}

/// <track>: speed in m/s, course in degrees true.
public struct Track: Sendable, Equatable {
    public var speed: Double
    public var course: Double

    public init(speed: Double, course: Double) {
        self.speed = speed; self.course = course
    }

    public init?(_ detail: CotDetail?) {
        guard let detail, detail.name == "track" else { return nil }
        self.init(speed: detail["speed"].flatMap(Double.init) ?? 0,
                  course: detail["course"].flatMap(Double.init) ?? 0)
    }

    /// getSelfEvent: NaN speed, and NaN or wild course (beyond ±3600°), go
    /// out as 0.
    public var detail: CotDetail {
        let speed = speed.isNaN ? 0 : speed
        let course = course.isNaN || abs(course) > 3600 ? 0 : course
        var d = CotDetail("track")
        d["speed"] = Cot.number(speed); d["course"] = Cot.number(course)
        return d
    }
}
