// Locating.swift — where a click is, for the tools under test: the ground as
// a place with no elevation data ("???"), an item at its marker's point or
// at `places`.

import Foundation
import MacTAKCot
@testable import MacTAKComms

@MainActor
func locating(_ markers: CotMarkerStore, places: [String: CotPoint] = [:]) -> (MapPick) -> SourcedPoint? {
    { pick in
        switch pick {
        case .ground(let p): return .clicked(p, altitudeSource: nil)
        case .item(let uid): return (markers[uid]?.point ?? places[uid]).map { SourcedPoint($0, precision: nil) }
        }
    }
}
