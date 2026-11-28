// CotDelete.swift — ATAK 5.5's delete task (t-x-d-d, G3 clean-code
// re-audit, N2), read as CotDeleteImporter reads it: the type exactly
// t-x-d-d (CotDeleteEventMarshal routes any type that starts with it, the
// importer then refuses all but this one), a <link> with a uid, a relation
// and a type, none of them empty, and <__forcedelete> when it is there.
// What a task does to the map is MapItems.importDelete.

public struct CotDelete: Equatable, Sendable {
    /// CotDeleteEventMarshal.COT_TASK_DISPLAY_DELETE_TYPE.
    public static let type = "t-x-d-d"

    /// The item it names (its link's uid).
    public var uid: String
    /// Remove the item (<__forcedelete>), not only make it stale.
    public var force: Bool

    public init(uid: String, force: Bool) {
        self.uid = uid
        self.force = force
    }

    /// The task `event` is, or nil when CotDeleteImporter would refuse it.
    public static func parse(_ event: CotEvent) -> CotDelete? {
        guard event.type == type, let link = event.detail("link"),
              let uid = link["uid"], !uid.isEmpty,
              link["relation"]?.isEmpty == false, link["type"]?.isEmpty == false else { return nil }
        return CotDelete(uid: uid, force: event.detail("__forcedelete") != nil)
    }
}
