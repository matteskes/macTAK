// RouteEvent.swift — a route as CoT, "b-m-r" (G3.10a), as ATAK 5.5 writes
// it (EditablePolyline.toCot, Route.toCot, then the detail handlers
// CotDetailManager runs for a route) and reads it (RouteImporter,
// EditablePolylineImporter.loadPoints, then the handlers).
//
// Written, field by field:
//   - the event: version 2.0, the route's uid, type b-m-r, how h-e, time
//     and start now, stale a day on, access Undefined. The point is never
//     set ("set the point to the first waypoint" is a comment with no
//     code), so it is the kernel's CotPoint.ZERO.
//   - a <link> per point, in order: point ("lat,lon" or "lat,lon,hae",
//     CotPoint.decimate: 7 decimals, the altitude to 3), type, uid,
//     relation "c", callsign and remarks ("" when the marker has none).
//   - <link_attr>: color, stroke (the weight as an int), style (the line
//     style's int), type (transport), method, direction, routetype, order,
//     planningmethod, prefix.
//   - then the handlers, in the order they are registered (5.5 runs them
//     out of a HashSet, in no set order): <contact callsign> the title
//     (ContactDetailHandler); <precisionlocation altsrc> for the route's
//     centre (PrecisionLocationHandler over Shape.getCenter, which looks
//     the altitude up: the elevation data's source, else "???");
//     <remarks> when it has some (RemarksDetailHandler); <archive/>
//     (ArchiveDetailHandler; every route is); <creator>
//     (CreatorDetailHandler, from setAuthorInformation in the route
//     tool); <color value> (ColorDetailHandler, a shape's as value);
//     <labels_on value> (LabelDetailHandler, false unless labels are on);
//     <strokeColor value>, <strokeWeight value>, <strokeStyle value>
//     (StrokeFillDetailHandler: a route is a Shape, never closed, so no
//     fill); <__routeinfo><__navcues/> (NavigationCueHandler, registered
//     by RouteMapComponent; no cues in G3.10).
//
// Read, as RouteImporter reads it:
//   - a new route starts from the importer's defaults: white, Driving
//     (which makes the transport "Vehicle": setRouteMethod runs after
//     setTransportationType's "On Foot"), Infil, Primary, planning
//     method Infil, Ascending Check Points, the prefix and weight
//     getNewRoute gives;
//   - <link_attr> sets what it has: color (a value that isn't an int
//     fails the import), type, then prefix, method (which sets the
//     transport again), direction, routetype, planningmethod, order,
//     stroke, style; a value 5.5 doesn't know is ignored;
//   - each <link> with a point is a point (one without is dropped): a
//     link with no uid gets one, with no type is a control point; a
//     waypoint takes the link's callsign and remarks; any other type is
//     the map item with that uid when there is one, else a control point;
//   - fewer than two points refuses the route;
//   - then the handlers: <contact callsign> the title (a new route's
//     "Route n" without one), <remarks>, <creator>, <labels_on>, and
//     <strokeColor> (white when it doesn't parse), <strokeWeight> (6.0),
//     <strokeStyle> (solid), which set the line after <link_attr> did.

import Foundation

public enum RouteEvent {
    public static let how = "h-e"
    /// toCot's stale: a day.
    public static let staleSeconds: TimeInterval = 24 * 3600
    /// StrokeFillDetailHandler's LINE_STYLES, by basic line style.
    public static let lineStyles = ["solid", "dashed", "dotted", "outlined"]

    /// The route as 5.5's toCot writes it. `center` is where its centre's
    /// altitude came from (`Route.center`), nil when it can't be told.
    public static func make(_ route: Route, center: PrecisionLocation?, now: Date) -> CotEvent {
        var detail = CotDetail("detail")
        for p in route.points { detail.add(link(p)) }
        detail.add(linkAttr(route))
        if !route.title.isEmpty {
            var contact = CotDetail("contact")
            contact["callsign"] = route.title
            detail.add(contact)
        }
        if let precision = center?.detail { detail.add(precision) }
        if let remarks = route.remarks {
            var r = CotDetail("remarks")
            r.innerText = remarks
            detail.add(r)
        }
        if route.archived { detail.add(CotDetail("archive")) }
        if let creator = route.creator { detail.add(creator.creatorDetail) }
        func value(_ name: String, _ v: String) {
            var d = CotDetail(name)
            d["value"] = v
            detail.add(d)
        }
        value("color", String(route.color))
        value("labels_on", String(route.labelsOn))
        value("strokeColor", String(route.color))
        value("strokeWeight", Cot.number(route.strokeWeight))
        value("strokeStyle", lineStyles.indices.contains(route.strokeStyle) ? lineStyles[route.strokeStyle] : "solid")
        var routeInfo = CotDetail("__routeinfo")
        routeInfo.add(CotDetail("__navcues"))
        detail.add(routeInfo)
        var event = CotEvent(uid: route.id, type: Route.type, time: now, stale: now.addingTimeInterval(staleSeconds),
                             how: how, point: .zero, detail: detail)
        event.access = Cot.undefinedAccess
        return event
    }

    /// CotPoint.decimate(GeoPoint): "lat,lon", with ",hae" when the
    /// altitude is valid.
    public static func decimate(_ p: CotPoint) -> String {
        func rounded(_ v: Double, _ factor: Double) -> String { Cot.number((v * factor).rounded() / factor) }
        let latLon = rounded(p.lat, 1e7) + "," + rounded(p.lon, 1e7)
        return Altitude.isValid(p.hae) ? latLon + "," + rounded(p.hae, 1e3) : latLon
    }

    /// GeoPoint.parseGeoPoint: "lat,lon[,alt…]"; nil when lat or lon
    /// doesn't parse.
    public static func parsePoint(_ text: String) -> CotPoint? {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              lat.isFinite, lon.isFinite else { return nil }
        let hae = parts.count > 2 ? Double(parts[2]) ?? .nan : .nan
        return CotPoint(lat: lat, lon: lon, hae: hae)
    }

    private static func link(_ p: RoutePoint) -> CotDetail {
        var link = CotDetail("link")
        link["point"] = decimate(p.point)
        link["type"] = p.type
        link["uid"] = p.uid
        link["relation"] = "c"
        link["callsign"] = p.callsign ?? ""
        link["remarks"] = p.remarks ?? ""
        return link
    }

    private static func linkAttr(_ route: Route) -> CotDetail {
        var a = CotDetail("link_attr")
        a["color"] = String(route.color)
        a["stroke"] = String(Int(route.strokeWeight))
        a["style"] = String(route.strokeStyle)
        a["type"] = route.transportType
        a["method"] = route.method.rawValue
        a["direction"] = route.direction.rawValue
        a["routetype"] = route.kind.rawValue
        a["order"] = route.order.rawValue
        a["planningmethod"] = route.planningMethod
        a["prefix"] = route.prefix
        return a
    }

    /// A b-m-r event read onto `existing` (the route with its uid here, if
    /// any) as RouteImporter does; nil when it isn't a route or 5.5 would
    /// refuse it. `isItem` says whether a uid is a map item here; `newUID`
    /// makes a uid for a link without one; `newTitle` is a new route's
    /// name when it comes without one.
    public static func read(_ event: CotEvent, onto existing: Route?, isItem: (String) -> Bool,
                            newUID: () -> String = { UUID().uuidString },
                            newTitle: () -> String) -> Route? {
        guard event.type == Route.type, let detail = event.detail else { return nil }
        var route = existing ?? Route(id: event.uid, title: newTitle())
        if let attr = event.detail("link_attr") {
            guard let color = attr["color"].flatMap({ Int32($0) }) else { return nil }
            route.color = color
            if let type = attr["type"] { route.transportType = type }
            if let prefix = attr["prefix"] { route.prefix = prefix }
            if let method = attr["method"].flatMap(Route.Method.init(rawValue:)) { route.setMethod(method) }
            if let direction = attr["direction"].flatMap(Route.Direction.init(rawValue:)) { route.direction = direction }
            if let kind = attr["routetype"].flatMap(Route.Kind.init(rawValue:)) { route.kind = kind }
            if let planning = attr["planningmethod"] { route.planningMethod = planning }
            if let order = attr["order"].flatMap(Route.Order.init(named:)) { route.order = order }
            if let stroke = attr["stroke"].flatMap({ Int($0) }) { route.strokeWeight = Double(stroke) }
            if let style = attr["style"].flatMap({ Int($0) }) { route.strokeStyle = style }
        }
        let points = detail.children.filter { $0.name == "link" }.compactMap { point($0, isItem: isItem, newUID: newUID) }
        guard points.count >= 2 else { return nil }
        route.points = points

        if let callsign = event.detail("contact")?["callsign"], !callsign.isEmpty { route.title = callsign }
        if let remarks = event.detail("remarks") { route.remarks = remarks.innerText ?? "" }
        if let creator = Author(creator: event.detail("creator"), orTime: event.time) { route.creator = creator }
        if let labels = event.detail("labels_on") { route.labelsOn = labels["value"].map { $0.lowercased() == "true" } ?? true }
        if let stroke = event.detail("strokeColor") { route.color = stroke["value"].flatMap { Int32($0) } ?? Route.white }
        if let weight = event.detail("strokeWeight") { route.strokeWeight = weight["value"].flatMap { Double($0) } ?? 6.0 }
        if let style = event.detail("strokeStyle") { route.strokeStyle = style["value"].flatMap { lineStyles.firstIndex(of: $0) } ?? 0 }
        return route
    }

    /// RouteImporter.createMarker for one <link>.
    private static func point(_ link: CotDetail, isItem: (String) -> Bool, newUID: () -> String) -> RoutePoint? {
        guard let place = link["point"].flatMap(parsePoint) else { return nil }
        let uid = link["uid"] ?? newUID()
        let type = link["type"] ?? Route.controlPointType
        switch type {
        case Route.controlPointType:
            return .controlPoint(place, uid: uid)
        case Route.waypointType:
            return RoutePoint(uid: uid, type: type, point: place, callsign: link["callsign"], remarks: link["remarks"])
        default:
            return isItem(uid) ? RoutePoint(uid: uid, type: type, point: place) : .controlPoint(place, uid: uid)
        }
    }
}
