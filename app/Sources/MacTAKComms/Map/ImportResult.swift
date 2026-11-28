// ImportResult.swift — what an importer made of an event, ATAK 5.5's
// CommsMapComponent.ImportResult (G3 clean-code re-audit, N2). The routes,
// the R&B lines and the archive used to have one each.
//
// Not as 5.5: IGNORE ("no problems, but also not handled") has no case,
// as no importer here returns it; 5.5's importers return FAILURE for an
// event that isn't theirs, as these do.

public enum ImportResult: Equatable, Sendable {
    case success
    /// An item it names isn't here yet: try again later (StateSaverPublisher
    /// retries these after the rest).
    case deferred
    /// Not this importer's event, or one it refuses.
    case failure
}
