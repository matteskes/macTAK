// ReportingRate.swift — when to send the self-SA, and its stale (G3.4b).
//
// Ported from ATAK 5.5's com.atakmap.comms.ReportingRate, constants and
// quirks kept, so a peer sees a macTAK client at the rate it would see an
// Android one. Two streams:
//   reliable    to TAK servers (commo's SEND_TAK_SERVER)
//   unreliable  to the mesh (SEND_POINT_TO_POINT)
// A 1 s tick asks `tick`; it answers with the reports due.
//   - "Dynamic" (the default): the stationary rate below 1 mph, the max
//     rate at 30 mph and over, a straight line between.
//   - "Constant": one rate per stream.
//   - A report is due early when the last one's stale is 10 s away.
//   - Both streams report at once on an altitude change over 50 m, a speed
//     change over 7 mph, or `reportAsap` (a self detail changed).
// Upstream quirks kept: Dynamic pads both streams' stale with the reliable
// multiplier (2), where Constant uses 4 for the unreliable one; a stream's
// first report comes on the first tick (nothing was sent at time 0).

import Foundation

public struct ReportingRate: Sendable {
    public enum Stream: Sendable, Equatable { case reliable, unreliable }

    public struct Report: Sendable, Equatable {
        /// How long after now the event goes stale.
        public var staleMillis: Int
        public var stream: Stream
    }

    public enum Strategy: String, Sendable, Codable, CaseIterable { case dynamic = "Dynamic", constant = "Constant" }

    /// The rates, in seconds as ATAK's preferences hold them.
    public struct Settings: Sendable, Equatable, Codable {
        public var strategy: Strategy = .dynamic
        public var constantUnreliable = 3
        public var constantReliable = 15
        public var dynamicStationaryUnreliable = 30
        public var dynamicMinUnreliable = 20
        public var dynamicMaxUnreliable = 2
        public var dynamicStationaryReliable = 180
        public var dynamicMinReliable = 20
        public var dynamicMaxReliable = 2

        /// ATAK's defaults.
        public static let atak = Settings()

        /// Constant, both streams every `seconds` (tests, tools).
        public static func every(seconds: Int) -> Settings {
            var s = Settings()
            s.strategy = .constant
            s.constantUnreliable = seconds
            s.constantReliable = seconds
            return s
        }

        public init() {}
    }

    static let maxSpeed = 13.4112        // 30 mph, m/s
    static let minSpeed = 0.44704        // 1 mph
    static let altitudeThreshold = 50.0  // m
    static let speedThreshold = 3.12928  // 7 mph
    static let staleBuffer = 10_000      // ms
    static let stalePadding = 15_000     // ms
    static let unreliableMultiplier = 4
    static let reliableMultiplier = 2

    public var settings: Settings

    private struct Last {
        var time: Int64 = 0
        var stale = 0
    }
    private var constant = [Stream.unreliable: Last(), .reliable: Last()]
    private var dynamic = [Stream.unreliable: Last(), .reliable: Last()]
    private var lastAltitude: [Stream: Double] = [:]
    private var lastSpeed = [Stream.unreliable: -1.0, .reliable: -1.0]
    private var asap = false

    public init(_ settings: Settings = .atak) {
        self.settings = settings
    }

    /// Both streams report on the next tick.
    public mutating func reportAsap() {
        asap = true
    }

    /// The reports due at `now` (milliseconds on a monotonic clock).
    /// altitude is nil when unknown; speed in m/s, NaN when unknown.
    public mutating func tick(now: Int64, altitude: Double?, speed: Double) -> [Report] {
        if asap { return reportBoth(now, altitude, speed) }
        if let alt = altitude {
            if let last = lastAltitude[.unreliable], abs(alt - last) > Self.altitudeThreshold {
                asap = true
            } else if let last = lastAltitude[.reliable], abs(alt - last) > Self.altitudeThreshold {
                asap = true
            }
        }
        // NaN never compares greater: an unknown speed triggers nothing.
        if abs(speed - lastSpeed[.unreliable]!) > Self.speedThreshold
            || abs(speed - lastSpeed[.reliable]!) > Self.speedThreshold {
            asap = true
        }
        if asap { return reportBoth(now, altitude, speed) }

        var due: [Report] = []
        for stream in [Stream.unreliable, .reliable] {
            switch settings.strategy {
            case .constant:
                let rate = constantRate(stream)
                let last = constant[stream]!
                let delta = Int(now - last.time)
                if delta >= rate || last.stale - delta <= Self.staleBuffer {
                    let stale = rate * (stream == .unreliable ? Self.unreliableMultiplier : Self.reliableMultiplier)
                        + Self.stalePadding
                    due.append(Report(staleMillis: stale, stream: stream))
                    record(stream, constant: true, now, stale, altitude, speed)
                }
            case .dynamic:
                if let stale = dynamicStale(stream, speed: speed, now: now) {
                    due.append(Report(staleMillis: stale, stream: stream))
                    record(stream, constant: false, now, stale, altitude, speed)
                }
            }
        }
        return due
    }

    private func constantRate(_ stream: Stream) -> Int {
        1000 * max(0, stream == .unreliable ? settings.constantUnreliable : settings.constantReliable)
    }

    private func dynamicStale(_ stream: Stream, speed: Double, now: Int64) -> Int? {
        let s = settings
        let (stationary, minRate, maxRate) = stream == .unreliable
            ? (s.dynamicStationaryUnreliable, s.dynamicMinUnreliable, s.dynamicMaxUnreliable)
            : (s.dynamicStationaryReliable, s.dynamicMinReliable, s.dynamicMaxReliable)
        let rate: Int
        if speed.isNaN || speed < Self.minSpeed {
            rate = stationary * 1000
        } else if speed >= Self.maxSpeed {
            rate = maxRate * 1000
        } else {
            // upstream's scaling, verbatim (scaledspeed is a percentage
            // offset by MIN_SPEED_MS)
            let scaledSpeed = Self.minSpeed + ((speed - Self.minSpeed) * 100) / (Self.maxSpeed - Self.minSpeed)
            let r2 = Double(minRate * 1000 - maxRate * 1000)
            rate = Int((Double(minRate * 1000) - (scaledSpeed * r2) / 100).rounded())
        }
        let last = dynamic[stream]!
        let delta = Int(now - last.time)
        guard delta >= rate || last.stale - delta <= Self.staleBuffer else { return nil }
        return rate * Self.reliableMultiplier + Self.stalePadding
    }

    private mutating func reportBoth(_ now: Int64, _ altitude: Double?, _ speed: Double) -> [Report] {
        asap = false
        let isConstant = settings.strategy == .constant
        var reports: [Report] = []
        for stream in [Stream.unreliable, .reliable] {
            var stale = (isConstant ? constant : dynamic)[stream]!.stale
            record(stream, constant: isConstant, now, stale, altitude, speed)
            if stale < 1 {
                stale = constantRate(stream)
                    * (stream == .unreliable ? Self.unreliableMultiplier : Self.reliableMultiplier)
                    + Self.stalePadding
            }
            reports.append(Report(staleMillis: stale, stream: stream))
        }
        return reports
    }

    private mutating func record(_ stream: Stream, constant isConstant: Bool, _ now: Int64, _ stale: Int,
                                 _ altitude: Double?, _ speed: Double) {
        if isConstant { constant[stream] = Last(time: now, stale: stale) } else { dynamic[stream] = Last(time: now, stale: stale) }
        lastSpeed[stream] = speed
        lastAltitude[stream] = altitude
    }
}
