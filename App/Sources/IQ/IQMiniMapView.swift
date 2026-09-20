import SwiftUI

/// The top-down mini-map that rides in the corner of the trainer.
///
/// The first-person camera cannot show a defender standing behind you or one in the far corner,
/// and half of these reads are about somebody you can barely see. The map is the other half of the
/// picture: the same positions from `IQPath.position`, drawn from above, with the basket at the top
/// so the map and the view point the same way.
///
/// It redraws from `IQPlayScene.mapTime`, which the scene publishes about twelve times a second —
/// not every frame. Eleven dots do not need sixty redraws a second of anybody's battery.
struct IQMiniMapView: View {
    let scenario: IQScenario
    let time: Double
    /// Rings the cue player once the answer has been revealed.
    var highlight: String?

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 4
            let w = size.width - inset * 2, h = size.height - inset * 2
            // Court x ∈ [−7.5, 7.5] across, z ∈ [0, 14] down, basket at the top.
            func point(_ x: Double, _ z: Double) -> CGPoint {
                CGPoint(x: inset + (CGFloat(x) + CGFloat(IQCourt.halfWidth))
                        / CGFloat(IQCourt.halfWidth * 2) * w,
                        y: inset + CGFloat(z) / CGFloat(IQCourt.halfLength) * h)
            }
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10),
                         with: .color(.black.opacity(0.55)))

            var lines = Path()
            lines.move(to: point(-IQCourt.halfWidth, 0))
            lines.addLine(to: point(IQCourt.halfWidth, 0))
            // The lane.
            lines.move(to: point(-IQCourt.laneHalfWidth, 0))
            lines.addLine(to: point(-IQCourt.laneHalfWidth, IQCourt.freeThrowZ))
            lines.addLine(to: point(IQCourt.laneHalfWidth, IQCourt.freeThrowZ))
            lines.addLine(to: point(IQCourt.laneHalfWidth, 0))
            // The arc, plus the two straight corner lines.
            let far = IQCourt.basketZ + (IQCourt.threePointRadius * IQCourt.threePointRadius
                                         - IQCourt.cornerLineX * IQCourt.cornerLineX).squareRoot()
            lines.move(to: point(IQCourt.cornerLineX, 0))
            lines.addLine(to: point(IQCourt.cornerLineX, far))
            lines.move(to: point(-IQCourt.cornerLineX, 0))
            lines.addLine(to: point(-IQCourt.cornerLineX, far))
            // The arc as a polyline in court coordinates, so which way "clockwise" means on a
            // flipped canvas never comes into it.
            let centre = point(0, IQCourt.basketZ)
            let startAngle = atan2(far - IQCourt.basketZ, IQCourt.cornerLineX)
            let steps = 28
            for i in 0...steps {
                let a = startAngle + (Double.pi - 2 * startAngle) * Double(i) / Double(steps)
                let q = point(IQCourt.threePointRadius * cos(a),
                              IQCourt.basketZ + IQCourt.threePointRadius * sin(a))
                if i == 0 { lines.move(to: q) } else { lines.addLine(to: q) }
            }
            context.stroke(lines, with: .color(.white.opacity(0.45)), lineWidth: 1)

            // The ring.
            context.stroke(Path(ellipseIn: CGRect(x: centre.x - 4, y: centre.y - 4, width: 8, height: 8)),
                           with: .color(.orange.opacity(0.9)), lineWidth: 1.5)

            for actor in scenario.actors {
                let p = IQPath.position(actor.track, at: time)
                let c = point(p.x, p.z)
                let r: CGFloat = actor.isUser ? 5 : 4
                let colour: Color = actor.side == .offence
                    ? Color(red: 0.30, green: 0.58, blue: 1.00)
                    : Color(red: 0.91, green: 0.29, blue: 0.31)
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.fill(dot, with: .color(colour))
                if actor.isUser {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - r - 2.5, y: c.y - r - 2.5,
                                                          width: (r + 2.5) * 2, height: (r + 2.5) * 2)),
                                   with: .color(.white), lineWidth: 1.6)
                }
                if let highlight, highlight == actor.id {
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - r - 4, y: c.y - r - 4,
                                                          width: (r + 4) * 2, height: (r + 4) * 2)),
                                   with: .color(Color(red: 1.0, green: 0.84, blue: 0.20)), lineWidth: 2)
                }
            }

            let b = IQPath.position(scenario.ball, at: time, defaultHeight: 1.0)
            let bc = point(b.x, b.z)
            context.fill(Path(ellipseIn: CGRect(x: bc.x - 2.6, y: bc.y - 2.6, width: 5.2, height: 5.2)),
                         with: .color(Color(red: 0.95, green: 0.51, blue: 0.16)))
        }
        .accessibilityHidden(true)
    }
}
