// The item stores' `receive` for a CoT event's XML, for the tests. The app
// parses a heard event once, in MapItems.receive, and hands each store the
// parsed event (G3 clean-code re-audit, N2); the tests mostly write XML.

import Foundation
@testable import MacTAKComms
import MacTAKCot

extension ContactStore {
    @discardableResult
    func receive(_ xml: String, via path: Contact.Path, at now: Date = Date()) -> Bool {
        guard let event = try? CotEvent.parse(xml, now: now) else { return false }
        return receive(event, via: path, at: now)
    }
}

extension CotMarkerStore {
    @discardableResult
    func receive(_ xml: String, at now: Date = Date()) -> Bool {
        guard let heard = try? CotEvent.parse(xml, now: now) else { return false }
        return receive(heard, xml: xml, at: now)
    }
}

extension RangeBearingLines {
    @discardableResult
    func receive(_ xml: String, isMarker: (String) -> Bool) -> Bool {
        guard let event = try? CotEvent.parse(xml) else { return false }
        return receive(event, isMarker: isMarker)
    }
}

extension Routes {
    @discardableResult
    func receive(_ xml: String, isItem: (String) -> Bool) -> Bool {
        guard let event = try? CotEvent.parse(xml) else { return false }
        return receive(event, isItem: isItem)
    }
}
