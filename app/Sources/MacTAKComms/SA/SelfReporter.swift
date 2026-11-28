// SelfReporter.swift — keeps the client's self-SA current (G3.4b).
//
// It joins what the self-SA says: the details (SelfDetails), the location
// (the mode, CoreLocation's fix, a placed position), the battery. It pushes
// each change to the CommoClient, which reports on ReportingRate's pace. A
// change ATAK reports at once (callsign, team, role, …) goes out on the next
// tick; a new reporting setting applies from the next tick. The mode and a
// placed position persist in the settings store; the location service is
// optional, so tests and tools run without CoreLocation.

import Combine
import Foundation

@MainActor
public final class SelfReporter: ObservableObject {
    public let details: SelfDetails
    @Published public var mode: LocationMode { didSet { if mode != oldValue { modeChanged() } } }
    /// "Set my location": where this client is when no provider says.
    @Published public var placed: CotPoint? { didSet { if placed != oldValue { placedChanged() } } }
    /// The street address looked up for the placed position (ADDR), with
    /// the position it was looked up for (AddressDetail.locationHash).
    @Published public private(set) var placedAddress: (detail: AddressDetail, at: String)? {
        didSet { saveAddress() }
    }
    /// What the self-SA reports now.
    @Published public private(set) var location: SelfEvent.Location?
    /// How it is moving (still when placed): the self readout's speed and
    /// heading (G3.6b).
    @Published public private(set) var track = Track(speed: 0, course: 0)

    private let settings: SettingsStore
    /// CoreLocation, when this reporter uses it (its status is the app's).
    public let locator: LocationService?
    private var client: CommoClient?
    private var batteryTask: Task<Void, Never>?
    /// The last update sent: each waits for the one before, so the client
    /// never ends on an older state.
    private var lastPush: Task<Void, Never>?

    static let modeKey = "mactak.locationMode", placedKey = "mactak.placedLocation"
    static let addressKey = "mactak.placedAddress"
    static let batteryPeriod: Duration = .seconds(60)

    public init(settings: SettingsStore, details: SelfDetails, locator: LocationService? = nil) {
        self.settings = settings
        self.details = details
        self.locator = locator
        mode = settings.string(forKey: Self.modeKey).flatMap(LocationMode.init(rawValue:)) ?? .both
        placed = settings.string(forKey: Self.placedKey).flatMap(Self.point)
        placedAddress = settings.data(forKey: Self.addressKey)
            .flatMap { try? JSONDecoder().decode(StoredAddress.self, from: $0) }
            .map { ($0.detail, $0.at) }
        details.onChange = { [weak self] _ in self?.push() }
        locator?.onFix = { [weak self] _ in self?.push() }
        resolve()
    }

    /// Reports through this client from now on, and starts its reporting.
    public func attach(_ client: CommoClient) {
        self.client = client
        let settings = details.reporting
        Task { await client.startReporting(settings) }
        if mode != .manual { locator?.start() }
        push()
        batteryTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pushBattery()
                try? await Task.sleep(for: Self.batteryPeriod)
            }
        }
    }

    public func detach() {
        batteryTask?.cancel()
        batteryTask = nil
        locator?.stop()
        client = nil
    }

    private func modeChanged() {
        settings.set(mode.rawValue, forKey: Self.modeKey)
        if client != nil {
            if mode == .manual { locator?.stop() } else { locator?.start() }
        }
        push()
    }

    /// The placed position's address, while the position is still where
    /// it was looked up (to about a metre), as 5.5 keeps an address.
    public var addressOfPlaced: AddressDetail? {
        guard let placed, let placedAddress,
              placedAddress.at == AddressDetail.locationHash(lat: placed.lat, lon: placed.lon) else { return nil }
        return placedAddress.detail
    }

    /// Places this client at `point`, with the address looked up for it,
    /// or none.
    public func place(_ point: CotPoint?, address: AddressDetail?) {
        placedAddress = point.flatMap { p in
            address.map { ($0, AddressDetail.locationHash(lat: p.lat, lon: p.lon)) }
        }
        placed = point
    }

    private struct StoredAddress: Codable {
        let detail: AddressDetail
        let at: String
    }

    private func saveAddress() {
        settings.set(placedAddress.flatMap { try? JSONEncoder().encode(StoredAddress(detail: $0.detail, at: $0.at)) },
                     forKey: Self.addressKey)
    }

    private func placedChanged() {
        settings.set(placed.map(Self.text), forKey: Self.placedKey)
        push()
    }

    @discardableResult
    private func resolve() -> (location: SelfEvent.Location?, track: Track) {
        let chosen = SelfLocation.choose(mode: mode, fix: locator?.fix, placed: placed)
        if location != chosen.location { location = chosen.location }
        if track != chosen.track { track = chosen.track }
        return chosen
    }

    private func push() {
        let chosen = resolve()
        guard let client else { return }
        var draft = SelfEvent(uid: details.uid, callsign: details.callsign)
        details.apply(to: &draft)
        let identity = draft
        let reporting = details.reporting
        let previous = lastPush
        lastPush = Task {
            await previous?.value
            await client.setReportingSettings(reporting)
            await client.updateSelf { event in
                event.callsign = identity.callsign
                event.type = identity.type
                event.remarks = identity.remarks
                event.group = identity.group
                event.location = chosen.location
                event.track = chosen.track
            }
        }
    }

    private func pushBattery() {
        guard let client else { return }
        let percent = SelfLocation.batteryPercent()
        let previous = lastPush
        lastPush = Task {
            await previous?.value
            await client.updateSelf { $0.battery = percent }
        }
    }

    /// "lat,lon" or "lat,lon,hae".
    static func point(_ text: String) -> CotPoint? {
        TypedPosition.parse(text)
    }

    static func text(_ p: CotPoint) -> String {
        p.validAltitude.map { "\(p.lat),\(p.lon),\($0)" } ?? "\(p.lat),\(p.lon)"
    }
}
