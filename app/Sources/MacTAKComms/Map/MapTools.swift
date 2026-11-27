// The map tools, one running at a time: 5.5's ToolManagerBroadcastReceiver
// keeps one active tool, and beginning a tool ends the one running. Here
// each tool starts itself (its view's button, a menu), and starting one ends
// the others. A click on the map goes to the running tool.

import Combine
import Foundation

@MainActor
public final class MapTools {
    /// The tools, in the order a click goes to them if more than one ran.
    public enum Tool: CaseIterable, Sendable {
        case route, pointDropper, rangeBearing, pointMove
    }

    private let routeEditor: RouteEditor
    private let pointDropper: PointDropper
    private let rangeBearing: RangeBearingLines
    private let pointEditor: PointEditor
    private var starts: [AnyCancellable] = []

    public init(routeEditor: RouteEditor, pointDropper: PointDropper, rangeBearing: RangeBearingLines,
                pointEditor: PointEditor) {
        self.routeEditor = routeEditor
        self.pointDropper = pointDropper
        self.rangeBearing = rangeBearing
        self.pointEditor = pointEditor
        starts = [
            routeEditor.$editing.sink { [weak self] in if $0 != nil { self?.endAll(but: .route) } },
            pointDropper.$selected.sink { [weak self] in if $0 != nil { self?.endAll(but: .pointDropper) } },
            rangeBearing.$tool.sink { [weak self] in if $0 != .off { self?.endAll(but: .rangeBearing) } },
            pointEditor.$moving.sink { [weak self] in if $0 != nil { self?.endAll(but: .pointMove) } },
        ]
    }

    /// The running tool, if any.
    public var active: Tool? { Tool.allCases.first(where: isRunning) }

    public var isIdle: Bool { active == nil }

    /// Gives a click on the map to the running tool. False when none runs:
    /// the click then shows what it hit. `checkpoint`: the route tool adds a
    /// checkpoint (Option-click) instead of a waypoint.
    public func click(_ pick: MapPick, checkpoint: Bool = false) -> Bool {
        guard let active else { return false }
        if active == .route {
            routeEditor.click(pick, checkpoint: checkpoint)
            return true
        }
        let pick = groundIfRoutePoint(pick)
        switch active {
        case .pointDropper:
            // a click on a point it placed shows that point
            if case .item(let uid) = pick, pointDropper.isPlacedHere(uid) {
                pointEditor.inspect(uid)
            } else {
                pointDropper.click(pick)
            }
        case .rangeBearing: rangeBearing.click(pick)
        case .pointMove: pointEditor.click(pick)
        case .route: break
        }
        return true
    }

    /// The other tools take a route's point as the ground there.
    private func groundIfRoutePoint(_ pick: MapPick) -> MapPick {
        guard case .item(let uid) = pick, let place = routeEditor.point(of: uid) else { return pick }
        return .ground(place)
    }

    private func isRunning(_ tool: Tool) -> Bool {
        switch tool {
        case .route: routeEditor.editing != nil
        case .pointDropper: pointDropper.selected != nil
        case .rangeBearing: rangeBearing.tool != .off
        case .pointMove: pointEditor.moving != nil
        }
    }

    private func endAll(but started: Tool) {
        for tool in Tool.allCases where tool != started {
            end(tool)
        }
    }

    private func end(_ tool: Tool) {
        switch tool {
        case .route: routeEditor.end()
        case .pointDropper: pointDropper.end()
        case .rangeBearing: rangeBearing.endTool()
        case .pointMove: pointEditor.endMove()
        }
    }
}
