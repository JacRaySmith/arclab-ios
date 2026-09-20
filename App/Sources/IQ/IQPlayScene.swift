import Observation
import QuartzCore
import SceneKit
import UIKit

// ================================================================================================
// MARK: - The play, rendered from the user's own eyes
// ================================================================================================
//
// There is no game footage in this repo and none can be fetched, so "film" here is a rendered
// play: a court drawn to rulebook dimensions, ten capsules with jersey colours, a ball, and a
// camera sitting where the user's player stands at eye height, looking where that player looks.
//
// The scene is built once per scenario. Playback only writes transforms — no geometry, no
// materials and no arrays are created while the play runs — and the positions come from
// `IQPath.position`, the pure function `IQScenarioLibrary.selfCheck()` checks.
//
// Court markings drawn from the FIBA columns of the verified table in
// `docs/reference/sdk-and-licensing-research-2026-09-12.md` §6 (arc 6.75 m, corner line 0.90 m
// inside the sideline, free-throw line 5.80 m from the endline, basket centre 1.575 m, ring
// 3.05 m, backboard 1.80 × 1.05 m at 1.20 m from the endline). Four more numbers are needed to
// draw a court and are not in that table — the 15 m width, the 4.90 m lane, the 1.80 m free-throw
// circle and the 1.25 m no-charge semicircle, all FIBA Art. 2. They place paint on a picture;
// nothing the app reports is measured from them.

// MARK: - Jersey colours

enum IQPalette {
    /// The user's team. Blue reads as "us" and survives both colour-blindness types better than green.
    static let offence = UIColor(red: 0.30, green: 0.58, blue: 1.00, alpha: 1)
    /// The other team.
    static let defence = UIColor(red: 0.91, green: 0.29, blue: 0.31, alpha: 1)
    static let ball = UIColor(red: 0.95, green: 0.51, blue: 0.16, alpha: 1)
    static let cue = UIColor(red: 1.00, green: 0.84, blue: 0.20, alpha: 1)
    static let floor = UIColor(red: 0.76, green: 0.58, blue: 0.36, alpha: 1)
    static let paint = UIColor(red: 0.62, green: 0.42, blue: 0.26, alpha: 1)
    static let line = UIColor(white: 0.97, alpha: 1)
    /// The same colour as the gym walls, so the top of the wall does not print a line across
    /// the sky when the camera looks up.
    static let sky = UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
}

// MARK: - The court, drawn once into a texture

@MainActor
enum IQCourtTexture {
    private static var cached: UIImage?

    /// One image of the half court, 68 pixels to the metre. Drawing the markings into a texture
    /// instead of building a few hundred thin boxes keeps the scene at about twenty nodes.
    static func image() -> UIImage {
        if let cached { return cached }
        let pxPerMetre: CGFloat = 68
        let w = CGFloat(IQCourt.halfWidth * 2) * pxPerMetre
        let h = CGFloat(IQCourt.halfLength) * pxPerMetre
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            // Court coordinates → image coordinates. The endline is the top of the image, which is
            // where the plane's own +y ends up once it is laid flat in front of the camera.
            func p(_ x: Double, _ z: Double) -> CGPoint {
                CGPoint(x: (CGFloat(x) + CGFloat(IQCourt.halfWidth)) * pxPerMetre,
                        y: CGFloat(z) * pxPerMetre)
            }
            IQPalette.floor.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // The paint, a shade darker so the key reads at a glance.
            IQPalette.paint.setFill()
            cg.fill(CGRect(x: p(-IQCourt.laneHalfWidth, 0).x, y: 0,
                           width: CGFloat(IQCourt.laneHalfWidth * 2) * pxPerMetre,
                           height: CGFloat(IQCourt.freeThrowZ) * pxPerMetre))

            cg.setStrokeColor(IQPalette.line.cgColor)
            cg.setLineWidth(CGFloat(IQCourt.lineWidth) * pxPerMetre)
            cg.setLineCap(.butt)

            func line(_ a: (Double, Double), _ b: (Double, Double)) {
                cg.move(to: p(a.0, a.1)); cg.addLine(to: p(b.0, b.1)); cg.strokePath()
            }

            // Boundary: endline, both sidelines, half-way line.
            line((-IQCourt.halfWidth, 0), (IQCourt.halfWidth, 0))
            line((-IQCourt.halfWidth, 0), (-IQCourt.halfWidth, IQCourt.halfLength))
            line((IQCourt.halfWidth, 0), (IQCourt.halfWidth, IQCourt.halfLength))
            line((-IQCourt.halfWidth, IQCourt.halfLength), (IQCourt.halfWidth, IQCourt.halfLength))

            // The lane and the free-throw line.
            line((-IQCourt.laneHalfWidth, 0), (-IQCourt.laneHalfWidth, IQCourt.freeThrowZ))
            line((IQCourt.laneHalfWidth, 0), (IQCourt.laneHalfWidth, IQCourt.freeThrowZ))
            line((-IQCourt.laneHalfWidth, IQCourt.freeThrowZ), (IQCourt.laneHalfWidth, IQCourt.freeThrowZ))

            /// Arcs are drawn as polylines in court coordinates: a court angle of zero points along
            /// +x and a positive angle turns into the court, whichever way the image is flipped.
            func arc(centre: (Double, Double), radius: Double, from: Double, to: Double) {
                let steps = 48
                for i in 0...steps {
                    let a = from + (to - from) * Double(i) / Double(steps)
                    let q = p(centre.0 + radius * cos(a), centre.1 + radius * sin(a))
                    if i == 0 { cg.move(to: q) } else { cg.addLine(to: q) }
                }
                cg.strokePath()
            }
            // Free-throw circle (FIBA 1.80 m) and the no-charge semicircle (FIBA 1.25 m).
            arc(centre: (0, IQCourt.freeThrowZ), radius: 1.80, from: 0, to: .pi * 2)
            arc(centre: (0, IQCourt.basketZ), radius: 1.25, from: 0, to: .pi)
            // Centre circle, half of it on this side of the half-way line.
            arc(centre: (0, IQCourt.halfLength), radius: 1.80, from: .pi, to: .pi * 2)

            // The three-point line: two straight corner lines and the arc between them. The corner
            // line runs from the endline to where it meets the arc — which is why the corner shot
            // is shorter than the one at the top of the key.
            let far = IQCourt.basketZ + (IQCourt.threePointRadius * IQCourt.threePointRadius
                                         - IQCourt.cornerLineX * IQCourt.cornerLineX).squareRoot()
            line((IQCourt.cornerLineX, 0), (IQCourt.cornerLineX, far))
            line((-IQCourt.cornerLineX, 0), (-IQCourt.cornerLineX, far))
            let start = atan2(far - IQCourt.basketZ, IQCourt.cornerLineX)
            arc(centre: (0, IQCourt.basketZ), radius: IQCourt.threePointRadius,
                from: start, to: .pi - start)
        }
        cached = image
        return image
    }
}

// MARK: - Labels above the players

@MainActor
enum IQLabelTexture {
    private static var cache: [String: UIImage] = [:]

    /// A short word on a dark plate, drawn once per distinct label and reused.
    static func image(_ text: String, tint: UIColor) -> UIImage {
        let key = "\(text)|\(tint.hashValue)"
        if let hit = cache[key] { return hit }
        let size = CGSize(width: 360, height: 96)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let plate = CGRect(x: 6, y: 6, width: size.width - 12, height: size.height - 12)
            UIColor(white: 0.06, alpha: 0.82).setFill()
            UIBezierPath(roundedRect: plate, cornerRadius: 22).fill()
            tint.setStroke()
            let border = UIBezierPath(roundedRect: plate, cornerRadius: 22)
            border.lineWidth = 5
            border.stroke()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: style,
            ]
            let bounds = CGRect(x: 10, y: (size.height - 54) / 2, width: size.width - 20, height: 54)
            (text as NSString).draw(in: bounds, withAttributes: attributes)
            _ = ctx
        }
        cache[key] = image
        return image
    }
}

// MARK: - One player's nodes

@MainActor
private final class IQActorNode {
    let root = SCNNode()
    private let label = SCNNode()
    private let ring = SCNNode()

    init(actor: IQActor, isUser: Bool, index: Int) {
        let tint = actor.side == .offence ? IQPalette.offence : IQPalette.defence

        if !isUser {
            let body = SCNCapsule(capRadius: 0.21, height: 1.55)
            body.firstMaterial?.diffuse.contents = tint
            body.firstMaterial?.roughness.contents = 0.85
            let bodyNode = SCNNode(geometry: body)
            bodyNode.position = SCNVector3(0, 0.78, 0)
            root.addChildNode(bodyNode)

            let head = SCNSphere(radius: 0.135)
            head.firstMaterial?.diffuse.contents = UIColor(white: 0.86, alpha: 1)
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(0, 1.72, 0)
            root.addChildNode(headNode)

            // A flat disc under the feet: without it players look like they float.
            let shadow = SCNCylinder(radius: 0.34, height: 0.012)
            shadow.firstMaterial?.diffuse.contents = UIColor(white: 0, alpha: 0.30)
            shadow.firstMaterial?.lightingModel = .constant
            let shadowNode = SCNNode(geometry: shadow)
            shadowNode.position = SCNVector3(0, 0.008, 0)
            root.addChildNode(shadowNode)

            let plate = SCNPlane(width: 1.12, height: 0.30)
            plate.firstMaterial?.diffuse.contents = IQLabelTexture.image(actor.label, tint: tint)
            plate.firstMaterial?.lightingModel = .constant
            plate.firstMaterial?.isDoubleSided = true
            plate.firstMaterial?.writesToDepthBuffer = false
            label.geometry = plate
            // Two heights, alternating: neighbours in the same part of the floor are usually
            // next to each other in the actor list, and this keeps their names apart.
            label.position = SCNVector3(0, index % 2 == 0 ? 2.06 : 2.42, 0)
            label.renderingOrder = 10
            label.constraints = [SCNBillboardConstraint()]
            root.addChildNode(label)
        }

        // The highlight the reveal turns on, built now so nothing is created mid-play.
        let torus = SCNTorus(ringRadius: 0.62, pipeRadius: 0.055)
        torus.firstMaterial?.diffuse.contents = IQPalette.cue
        torus.firstMaterial?.emission.contents = IQPalette.cue
        torus.firstMaterial?.lightingModel = .constant
        ring.geometry = torus
        ring.position = SCNVector3(0, 0.04, 0)
        ring.isHidden = true
        root.addChildNode(ring)
    }

    func move(to p: IQPoint) {
        root.position = SCNVector3(Float(p.x), 0, Float(p.z))
    }

    /// Labels keep a roughly constant size on screen: a name two metres away and one twelve metres
    /// away are both readable on a phone. One scale write per frame, no allocation.
    func sizeLabel(cameraAt eye: SCNVector3) {
        guard label.geometry != nil else { return }
        let dx = root.position.x - eye.x, dz = root.position.z - eye.z
        let distance = (dx * dx + dz * dz).squareRoot()
        let s = min(max(Float(distance) / 6.5, 0.85), 1.7)
        label.scale = SCNVector3(s, s, s)
    }

    func setHighlighted(_ on: Bool) { ring.isHidden = !on }
}

// MARK: - The clock that drives playback

/// A display link with a main-actor owner. `CADisplayLink` retains its target, so the target is
/// this small object and the callback holds the scene weakly.
@MainActor
private final class IQTicker: NSObject {
    var onTick: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) { onTick?(link.timestamp) }
}

// MARK: - The scene

enum IQPlayState: Equatable, Sendable {
    /// Built, positioned at t = 0, waiting for a tap to start.
    case ready
    /// Running towards the freeze.
    case playing
    /// Stopped at `freezeAt`. The decision clock is running.
    case frozen
    /// The answer has been given; the play runs on to the end with the cue ringed.
    case revealing
    case finished
}

@MainActor
@Observable
final class IQPlayScene {
    let scenario: IQScenario
    let scene = SCNScene()
    let cameraNode = SCNNode()

    private(set) var state: IQPlayState = .ready
    /// The play's own time, in seconds. Published at about twelve times a second for the mini-map,
    /// not sixty: a `Canvas` redraw per frame is not worth the battery for eleven dots.
    private(set) var mapTime: Double = 0

    /// Set at the freeze, read at the tap. `CACurrentMediaTime` is monotonic, so a clock change
    /// or a phone call cannot turn a decision into a negative number.
    private(set) var freezeStartedAt: CFTimeInterval?

    var onFreeze: (() -> Void)?
    var onFinish: (() -> Void)?

    private var actorNodes: [IQActorNode] = []
    private let ballNode = SCNNode()
    private var time: Double = 0
    private var lastTick: CFTimeInterval?
    private var lastPublishedMapTime: Double = -1
    /// The index of the cue in `scenario.actors`, and the play time the reveal's pan began.
    private var cueIndex: Int?
    private var panStart: Double?
    private let ticker = IQTicker()
    private weak var view: SCNView?
    /// The reveal runs a little slower than real time so the finish can be followed.
    private var rate: Double = 1.0

    init(scenario: IQScenario) {
        self.scenario = scenario
        scene.background.contents = IQPalette.sky
        buildCourt()
        buildBasket()
        buildLights()

        for actor in scenario.actors {
            let node = IQActorNode(actor: actor, isUser: actor.isUser, index: actorNodes.count)
            actorNodes.append(node)
            scene.rootNode.addChildNode(node.root)
        }

        let ball = SCNSphere(radius: 0.122)
        ball.firstMaterial?.diffuse.contents = IQPalette.ball
        ball.firstMaterial?.roughness.contents = 0.6
        ballNode.geometry = ball
        scene.rootNode.addChildNode(ballNode)

        let camera = SCNCamera()
        // Wide: a player sees far more than a film lens does, and a narrow one hides the low man.
        camera.fieldOfView = CGFloat(IQCamera.horizontalFieldOfViewDegrees)
        camera.projectionDirection = .horizontal
        camera.zNear = 0.05
        camera.zFar = 80
        camera.wantsHDR = false
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        ticker.onTick = { [weak self] now in self?.tick(now) }
        apply(time: 0)
    }

    // MARK: Building

    private func buildCourt() {
        // Floor beyond the lines, then four walls. Two nodes, drawn once, and they give the
        // picture a horizon — depth on a phone screen comes from the room, not from the court.
        let surround = SCNPlane(width: 72, height: 72)
        surround.firstMaterial?.diffuse.contents = UIColor(red: 0.20, green: 0.16, blue: 0.13, alpha: 1)
        surround.firstMaterial?.roughness.contents = 1.0
        let surroundNode = SCNNode(geometry: surround)
        surroundNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        surroundNode.position = SCNVector3(0, -0.02, Float(IQCourt.halfLength / 2))
        scene.rootNode.addChildNode(surroundNode)

        // Tall, and with its floor well below the court: a cylinder whose end cap sits at y = 0
        // fights the court plane for the same pixels and draws dark wedges across the floor.
        let room = SCNCylinder(radius: 26, height: 44)
        room.radialSegmentCount = 28
        let wall = SCNMaterial()
        wall.diffuse.contents = UIColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1)
        wall.isDoubleSided = true
        wall.lightingModel = .constant
        room.materials = [wall]
        let roomNode = SCNNode(geometry: room)
        roomNode.position = SCNVector3(0, 18, Float(IQCourt.halfLength / 2))
        scene.rootNode.addChildNode(roomNode)

        let plane = SCNPlane(width: CGFloat(IQCourt.halfWidth * 2), height: CGFloat(IQCourt.halfLength))
        let material = plane.firstMaterial
        material?.diffuse.contents = IQCourtTexture.image()
        material?.diffuse.mipFilter = .linear
        material?.diffuse.maxAnisotropy = 8
        material?.diffuse.wrapS = .clamp
        material?.diffuse.wrapT = .clamp
        material?.roughness.contents = 0.95
        let node = SCNNode(geometry: plane)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(0, 0, Float(IQCourt.halfLength / 2))
        scene.rootNode.addChildNode(node)
    }

    private func buildBasket() {
        // Backboard: 1.80 × 1.05 m, face 1.20 m from the endline, lower edge 2.90 m up.
        let board = SCNBox(width: CGFloat(IQCourt.backboardWidth), height: CGFloat(IQCourt.backboardHeight),
                           length: 0.05, chamferRadius: 0)
        board.firstMaterial?.diffuse.contents = UIColor(white: 0.93, alpha: 1)
        board.firstMaterial?.transparency = 0.9
        let boardNode = SCNNode(geometry: board)
        boardNode.position = SCNVector3(0, Float(2.90 + IQCourt.backboardHeight / 2), Float(IQCourt.backboardZ))
        scene.rootNode.addChildNode(boardNode)

        let inner = SCNBox(width: 0.61, height: 0.46, length: 0.01, chamferRadius: 0)
        inner.firstMaterial?.diffuse.contents = UIColor(red: 0.85, green: 0.24, blue: 0.24, alpha: 1)
        let innerNode = SCNNode(geometry: inner)
        innerNode.position = SCNVector3(0, Float(3.05 + 0.15), Float(IQCourt.backboardZ + 0.04))
        scene.rootNode.addChildNode(innerNode)

        let ring = SCNTorus(ringRadius: CGFloat(IQCourt.rimInnerRadius), pipeRadius: 0.012)
        ring.firstMaterial?.diffuse.contents = IQPalette.ball
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, Float(IQCourt.rimHeight), Float(IQCourt.basketZ))
        scene.rootNode.addChildNode(ringNode)

        let post = SCNBox(width: 0.24, height: 3.4, length: 0.24, chamferRadius: 0.02)
        post.firstMaterial?.diffuse.contents = UIColor(white: 0.22, alpha: 1)
        let postNode = SCNNode(geometry: post)
        postNode.position = SCNVector3(0, 1.7, Float(IQCourt.backboardZ - 0.9))
        scene.rootNode.addChildNode(postNode)
    }

    private func buildLights() {
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.light?.castsShadow = false
        key.position = SCNVector3(3, 9, 9)
        key.look(at: SCNVector3(0, 0, 5))
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 620
        scene.rootNode.addChildNode(fill)
    }

    // MARK: Playback

    func attach(_ view: SCNView) {
        self.view = view
        view.scene = scene
        view.pointOfView = cameraNode
        view.rendersContinuously = state == .playing || state == .revealing
    }

    func start() {
        guard state == .ready else { return }
        state = .playing
        lastTick = nil
        rate = 1.0
        view?.rendersContinuously = true
        ticker.start()
    }

    /// Called after the user has chosen. Rings the cue and lets the play run out.
    func reveal() {
        guard state == .frozen else { return }
        if let cue = scenario.cueActorID,
           let index = scenario.actors.firstIndex(where: { $0.id == cue }) {
            actorNodes[index].setHighlighted(true)
            cueIndex = index
            panStart = time
        }
        state = .revealing
        lastTick = nil
        rate = 0.7
        view?.rendersContinuously = true
        ticker.start()
    }

    func stop() {
        ticker.stop()
        view?.rendersContinuously = false
    }

    private func tick(_ now: CFTimeInterval) {
        guard state == .playing || state == .revealing else { return }
        let previous = lastTick ?? now
        lastTick = now
        // A frame that took longer than a fifth of a second means the app was away; do not jump.
        let dt = min(max(now - previous, 0), 0.2) * rate
        var t = time + dt

        if state == .playing, t >= scenario.freezeAt {
            t = scenario.freezeAt
            apply(time: t)
            state = .frozen
            freezeStartedAt = CACurrentMediaTime()
            ticker.stop()
            view?.rendersContinuously = false
            view?.setNeedsDisplay()
            onFreeze?()
            return
        }
        if state == .revealing, t >= scenario.duration {
            t = scenario.duration
            apply(time: t)
            state = .finished
            ticker.stop()
            view?.rendersContinuously = false
            view?.setNeedsDisplay()
            onFinish?()
            return
        }
        apply(time: t)
    }

    /// The whole of playback. Writes transforms only: no geometry, no materials, no arrays.
    private func apply(time t: Double) {
        time = t
        for (i, actor) in scenario.actors.enumerated() {
            actorNodes[i].move(to: IQPath.position(actor.track, at: t))
        }
        let b = IQPath.position(scenario.ball, at: t, defaultHeight: 1.0)
        ballNode.position = SCNVector3(Float(b.x), Float(b.y), Float(b.z))

        // On the reveal the head turns towards the ringed player, so the cue the paragraph names
        // is the thing in the middle of the picture. Half a second, eased, not a cut.
        var pan: IQPoint?
        if state == .revealing, let cueIndex, let panStart {
            let progress = IQPath.smoothstep((t - panStart) / 0.6) * 0.6
            let cue = IQPath.position(scenario.actors[cueIndex].track, at: t)
            let base = scenario.gazeTarget(at: t)
            pan = IQPoint(x: base.x + (cue.x - base.x) * progress,
                          z: base.z + (cue.z - base.z) * progress,
                          y: base.y + (1.45 - base.y) * progress)
        }
        // `cameraPlacement` owns the eye height, the set-back and the too-close-to-look-at case,
        // and the self-check reads the same function — so what ships is what was checked.
        let placement = scenario.cameraPlacement(at: t, lookingAt: pan)
        let eyeNode = SCNVector3(Float(placement.eye.x), Float(placement.eye.y), Float(placement.eye.z))
        cameraNode.position = eyeNode
        cameraNode.look(at: SCNVector3(Float(placement.target.x), Float(placement.target.y), Float(placement.target.z)),
                        up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        for node in actorNodes { node.sizeLabel(cameraAt: eyeNode) }

        // The mini-map is a separate, much cheaper drawing; twelve updates a second is plenty.
        if (t - lastPublishedMapTime).magnitude >= 1.0 / 12 || t == 0 || t >= scenario.duration {
            lastPublishedMapTime = t
            mapTime = t
        }
    }

    /// Milliseconds from the freeze to now, or nil if the play is not frozen. Never negative.
    func decisionMilliseconds() -> Int? {
        guard let start = freezeStartedAt else { return nil }
        return Int(max(0, (CACurrentMediaTime() - start) * 1000).rounded())
    }
}
