import SwiftUI
import RealityKit
import ARKit
import Combine

// MARK: - Model (shared between SwiftUI and the AR view)

enum SpawnShape: String, CaseIterable, Identifiable {
    case cube, sphere, brick
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .cube: return "cube.fill"
        case .sphere: return "circle.fill"
        case .brick: return "rectangle.fill"
        }
    }
}

enum SpawnChoice: Hashable {
    case primitive(SpawnShape)
    case usdz(String)
}

final class SceneModel: ObservableObject {
    // What to spawn
    @Published var choice: SpawnChoice = .primitive(.cube)
    @Published var colorIndex = 0
    @Published var showMesh = true
    @Published private(set) var count = 0

    // Hand tracking (screen points)
    @Published var handTracking = false
    @Published var thumbPoint: CGPoint?
    @Published var indexPoint: CGPoint?
    @Published var isPinching = false
    
    @Published var isHolding = false
    private var grabbed: ModelEntity?
    private var grabPoint: CGPoint = .zero          // ring position on screen
    private var grabDistance: Float = 0.6           // metres from the camera
    private var grabVelocity = SIMD3<Float>.zero    // smoothed, for throwing

    let palette: [Color] = [.blue, .orange, .pink, .green, .white]

    // Every .usdz and .reality file in the app bundle, found automatically
    let modelNames: [String] = Array(Set(
        ["usdz", "reality"].flatMap { ext in
            Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }.map { $0.deletingPathExtension().lastPathComponent }
    )).sorted()

    weak var arView: ARView?

    private var spawned: [AnchorEntity] = []
    private var cache: [String: Entity] = [:]   // load from disk once, clone after
    private let maxObjects = 40

    var usesColor: Bool {
        if case .primitive = choice { return true }
        return false
    }

    // MARK: Spawning

    func spawn(at position: SIMD3<Float>) {
        guard arView != nil else { return }
        switch choice {
        case .primitive(let shape):
            add(makePrimitive(shape), at: position)
        case .usdz(let name):
            Task { @MainActor in
                if let body = await makeModel(named: name) {
                    add(body, at: position)
                }
            }
        }
    }

    private func configurePhysics(_ body: ModelEntity, shapes: [ShapeResource]) {
        body.name = "spawned"   // lets the tap handler recognise our objects
        body.collision = CollisionComponent(shapes: shapes)
        body.physicsBody = PhysicsBodyComponent(
            shapes: shapes,
            mass: 0.5,
            material: .generate(friction: 0.6, restitution: 0.4),
            mode: .dynamic
        )
    }

    private func makePrimitive(_ shape: SpawnShape) -> ModelEntity {
        let mesh: MeshResource
        let shapes: [ShapeResource]
        switch shape {
        case .cube:
            mesh = .generateBox(size: 0.1, cornerRadius: 0.005)
            shapes = [.generateBox(size: [0.1, 0.1, 0.1])]
        case .sphere:
            mesh = .generateSphere(radius: 0.05)
            shapes = [.generateSphere(radius: 0.05)]
        case .brick:
            mesh = .generateBox(width: 0.16, height: 0.05, depth: 0.08, cornerRadius: 0.005)
            shapes = [.generateBox(size: [0.16, 0.05, 0.08])]
        }
        let material = SimpleMaterial(color: UIColor(palette[colorIndex]), isMetallic: false)
        let body = ModelEntity(mesh: mesh, materials: [material])
        configurePhysics(body, shapes: shapes)
        return body
    }

    private func makeModel(named name: String) async -> ModelEntity? {
        do {
            // Load from disk only the first time; clone afterwards
            let template: Entity
            if let cached = cache[name] {
                template = cached
            } else {
                template = try await Entity(named: name)
                cache[name] = template
            }
            let clone = template.clone(recursive: true)

            // A .reality scene often has an AnchorEntity root with its own placement
            // rules. Move its contents into a plain entity so only our anchor decides.
            let loaded: Entity
            if clone is AnchorEntity {
                loaded = Entity()
                for child in Array(clone.children) { loaded.addChild(child) }
            } else {
                loaded = clone
            }

            // Pivot: leaves the asset's own root transform (unit scale etc.) alone
            let pivot = Entity()
            pivot.addChild(loaded)

            // Measure in the pivot's space, including the asset's built-in scale
            let bounds = pivot.visualBounds(relativeTo: pivot)
            let longest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
            guard longest > 0 else { return nil }

            let targetSize: Float = 0.12   // longest side in meters; tune by eye
            let s = targetSize / longest
            pivot.scale = SIMD3<Float>(repeating: s)
            pivot.position = -bounds.center * s

            // Wrapper holds the physics; the model rides inside it
            let body = ModelEntity()
            body.addChild(pivot)
            configurePhysics(body, shapes: [.generateBox(size: bounds.extents * s)])
            return body
        } catch {
            print("Model load error for \(name): \(error)")
            return nil
        }
    }

    private func add(_ body: ModelEntity, at position: SIMD3<Float>) {
        guard let arView else { return }

        // Drop from above, slightly tilted so it tumbles on landing
        body.position.y = 0.4
        body.orientation = simd_quatf(angle: .random(in: 0...(.pi / 2)),
                                      axis: normalize(SIMD3<Float>(1, 0, 1)))

        let anchor = AnchorEntity(world: position)
        anchor.addChild(body)
        arView.scene.addAnchor(anchor)

        spawned.append(anchor)
        if spawned.count > maxObjects { spawned.removeFirst().removeFromParent() }
        count = spawned.count
    }

    // MARK: Interaction

    func flick(_ body: ModelEntity) {
        guard let arView else { return }

        let z = arView.cameraTransform.matrix.columns.2
        var dir = -SIMD3<Float>(z.x, 0, z.z)
        dir = length(dir) < 0.01 ? SIMD3<Float>(0, 0, -1) : normalize(dir)
        dir += SIMD3<Float>(0, 0.6, 0)

        body.applyLinearImpulse(dir * 0.8, relativeTo: nil)
        body.applyAngularImpulse(SIMD3<Float>(Float.random(in: -0.004...0.004),
                                              Float.random(in: -0.004...0.004),
                                              Float.random(in: -0.004...0.004)),
                                 relativeTo: nil)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func undo() {
        guard let last = spawned.popLast() else { return }
        last.removeFromParent()
        count = spawned.count
    }

    func clear() {
        spawned.forEach { $0.removeFromParent() }
        spawned.removeAll()
        count = 0
    }

    // MARK: Hand tracking

    func apply(_ sample: HandSample?) {
        let wasPinching = isPinching
        thumbPoint = sample?.thumb
        indexPoint = sample?.index
        isPinching = sample?.pinching ?? false

        // Hand lost: drop whatever we're holding, with no throw
        guard let sample else { endGrab(throwing: false); return }

        let mid = CGPoint(x: (sample.thumb.x + sample.index.x) / 2,
                          y: (sample.thumb.y + sample.index.y) / 2)

        if sample.pinching {
            // Only a pinch that *starts* near an object grabs it
            if grabbed == nil && !wasPinching { beginGrab(at: mid) }
            grabPoint = mid
        } else {
            endGrab(throwing: true)
        }
    }

    private func beginGrab(at point: CGPoint) {
        guard let arView else { return }

        // Pick the object whose centre is closest to the ring, within 90 points
        var best: ModelEntity?
        var bestDistance: CGFloat = 90
        for anchor in spawned {
            guard let body = anchor.children.first as? ModelEntity,
                  let p = arView.project(body.position(relativeTo: nil)) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < bestDistance { best = body; bestDistance = d }
        }
        guard let body = best else { return }

        // Keep the object at the distance it already is from the camera
        let cameraPos = arView.cameraTransform.translation
        grabDistance = min(max(distance(cameraPos, body.position(relativeTo: nil)), 0.25), 2.0)
        grabVelocity = .zero
        grabbed = body
        isHolding = true

        // Kinematic: moved by our code, ignores gravity
        body.physicsBody?.mode = .kinematic
        body.physicsMotion = PhysicsMotionComponent(linearVelocity: .zero, angularVelocity: .zero)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Called every frame (60 Hz) from the AR session delegate.
    func updateGrab(dt: Float) {
        guard let arView, let body = grabbed else { return }

        // The object may have been removed by undo, clear, or the object cap
        guard body.scene != nil else { grabbed = nil; isHolding = false; return }
        guard let ray = arView.ray(through: grabPoint) else { return }

        // Point on the ray at the grab distance, then glide toward it
        let target = ray.origin + normalize(ray.direction) * grabDistance
        let current = body.position(relativeTo: nil)
        let k = 1 - exp(-dt * 18)
        let next = current + (target - current) * k
        body.setPosition(next, relativeTo: nil)

        // Running average of velocity, used for the throw
        grabVelocity = grabVelocity * 0.7 + ((next - current) / dt) * 0.3
    }

    private func endGrab(throwing: Bool) {
        guard let body = grabbed else { return }
        grabbed = nil
        isHolding = false

        var velocity: SIMD3<Float> = throwing ? grabVelocity : .zero
        let speed = length(velocity)
        if speed > 4 { velocity *= 4 / speed }   // clamp at 4 m/s

        body.physicsBody?.mode = .dynamic
        body.physicsMotion = PhysicsMotionComponent(linearVelocity: velocity, angularVelocity: .zero)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func toggleHandTracking() {
        handTracking.toggle()
        if !handTracking { apply(nil) }
    }
}

// MARK: - SwiftUI

struct ContentView: View {
    @StateObject private var model = SceneModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainer(model: model).ignoresSafeArea()
            HandCursor(model: model)
            ControlTray(model: model)
        }
    }
}

struct ControlTray: View {
    @ObservedObject var model: SceneModel

    private func chip<Content: View>(selected: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(selected ? Color.white.opacity(0.25) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
    }

    var body: some View {
        VStack(spacing: 14) {
            // Row 1: what to spawn
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpawnShape.allCases) { s in
                        Button { model.choice = .primitive(s) } label: {
                            chip(selected: model.choice == .primitive(s)) {
                                Image(systemName: s.icon).font(.title3)
                            }
                        }
                    }
                    if !model.modelNames.isEmpty {
                        Divider().frame(height: 24)
                    }
                    ForEach(model.modelNames, id: \.self) { name in
                        Button { model.choice = .usdz(name) } label: {
                            chip(selected: model.choice == .usdz(name)) {
                                Text(name.replacingOccurrences(of: "_", with: " "))
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            // Row 2: color and actions
            HStack(spacing: 14) {
                ForEach(model.palette.indices, id: \.self) { i in
                    Circle()
                        .fill(model.palette[i])
                        .frame(width: 30, height: 30)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: model.colorIndex == i ? 3 : 0)
                                .padding(-5)
                        )
                        .onTapGesture { model.colorIndex = i }
                }
                .opacity(model.usesColor ? 1 : 0.3)
                .allowsHitTesting(model.usesColor)

                Spacer()

                Button { model.toggleHandTracking() } label: {
                    Image(systemName: model.handTracking ? "hand.raised.fill" : "hand.raised")
                        .frame(width: 44, height: 44)
                }
                Button { model.showMesh.toggle() } label: {
                    Image(systemName: model.showMesh ? "eye" : "eye.slash").frame(width: 44, height: 44)
                }
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
                }
                .disabled(model.count == 0)
                Button { model.clear() } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .disabled(model.count == 0)
            }

            Text("\(model.count) objects  ·  tap a surface to drop  ·  tap an object to flick")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - AR view

struct ARContainer: UIViewRepresentable {
    @ObservedObject var model: SceneModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        model.arView = view
        view.session.delegate = context.coordinator

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            view.environment.sceneUnderstanding.options.formUnion([.occlusion, .physics])
        }
        view.session.run(config)

        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.frame = view.bounds
        coaching.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(coaching)

        view.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator,
                                   action: #selector(Coordinator.handleTap(_:)))
        )
        return view
    }

    // SwiftUI calls this whenever the model changes: push state into UIKit here
    func updateUIView(_ view: ARView, context: Context) {
        if model.showMesh {
            view.debugOptions.insert(.showSceneUnderstanding)
        } else {
            view.debugOptions.remove(.showSceneUnderstanding)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    class Coordinator: NSObject, ARSessionDelegate {
        let model: SceneModel
        let tracker = HandTracker()
        var lastTimestamp: TimeInterval = 0

        init(model: SceneModel) { self.model = model }

        // Called by ARKit for every camera frame
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Move the held object every frame (60 Hz), between hand detections (15 Hz)
            let dt = Float(min(max(frame.timestamp - lastTimestamp, 0.001), 0.1))
            lastTimestamp = frame.timestamp
            model.updateGrab(dt: dt)

            guard model.handTracking, let view = model.arView else { return }
            tracker.process(frame: frame, viewSize: view.bounds.size) { [weak model] sample in
                model?.apply(sample)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = model.arView else { return }
            let point = gesture.location(in: view)

            // 1. Tap landed on one of our objects: flick it
            if let body = view.entity(at: point) as? ModelEntity, body.name == "spawned" {
                model.flick(body)
                return
            }

            // 2. Otherwise raycast to a surface and spawn there
            let hit = view.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
                   ?? view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
            guard let hit else { return }

            let t = hit.worldTransform.columns.3
            model.spawn(at: SIMD3<Float>(t.x, t.y, t.z))
        }
    }
}
