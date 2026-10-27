import SwiftUI
import UIKit
import RealityKit
import ARKit
import Combine

// MARK: - Root

struct ContentView: View {
    @StateObject private var model = SceneModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARContainer(model: model).ignoresSafeArea()
            HandCursor(model: model)
            ControlOverlay(model: model)
        }
    }
}

// MARK: - Helpers

enum Haptics {
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func tap()    { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// Call this where the app actually drops an object into the scene.
    static func place()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func warn()   { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

enum ModelIcon {
    /// SF Symbol for a model, keyed off its filename. Unknown models get a generic icon.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("fender") || n.contains("guitar") { return "guitars" }
        if n.contains("toy") || n.contains("plane")     { return "airplane" }
        return "cube.transparent"
    }

    /// Models that should not appear in the picker.
    static func isHidden(_ name: String) -> Bool {
        name.lowercased().contains("hab")
    }
}

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

/// What the app tells the user about the camera and the room.
enum ScanStatus: Equatable {
    case scanning              // tracking is fine, but no surface under the reticle yet
    case ready                 // a surface is under the reticle
    case limited(String)       // ARKit says tracking is degraded; the string is the reason

    var hint: String {
        switch self {
        case .scanning: return "Move the phone to scan"
        case .ready: return "Tap to place"
        case .limited(let why): return why.isEmpty ? "Tracking limited" : "Tracking limited · \(why)"
        }
    }
}

final class SceneModel: ObservableObject {
    // What to spawn
    @Published var choice: SpawnChoice = .primitive(.cube)
    @Published var colorIndex = 0
    @Published var showMesh = true
    @Published private(set) var count = 0
    @Published private(set) var status: ScanStatus = .scanning

    // Hand tracking (screen points)
    @Published var handTracking = false
    @Published var thumbPoint: CGPoint?
    @Published var indexPoint: CGPoint?
    @Published var isPinching = false
    @Published var isHolding = false

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

    // Reticle, placement and selection (updated every frame, not published)
    private var reticle: AnchorEntity?
    private var selectionRing: AnchorEntity?
    private var selected: ModelEntity?
    private var placementPosition: SIMD3<Float>?

    // Grabbing
    private var grabbed: ModelEntity?
    private var grabPoint: CGPoint = .zero          // ring position on screen
    private var grabDistance: Float = 0.6           // metres from the camera
    private var grabVelocity = SIMD3<Float>.zero    // smoothed, for throwing

    var usesColor: Bool {
        if case .primitive = choice { return true }
        return false
    }

    // MARK: Reticle and selection ring

    /// A flat ring in the XZ plane, made of triangles. Drawn from both sides so it never disappears.
    private static func ringMesh(inner: Float, outer: Float, segments: Int = 64) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            positions.append(SIMD3<Float>(cos(a) * inner, 0, sin(a) * inner))   // even index: inner edge
            positions.append(SIMD3<Float>(cos(a) * outer, 0, sin(a) * outer))   // odd index: outer edge
        }
        for i in 0..<segments {
            let i0 = UInt32(i * 2)
            let o0 = i0 + 1
            let next = UInt32(((i + 1) % segments) * 2)
            let i1 = next
            let o1 = next + 1
            // One quad = two triangles, added in both windings (visible from above and below)
            indices += [i0, o0, o1, i0, o1, i1]
            indices += [i0, o1, o0, i0, i1, o1]
        }
        var desc = MeshDescriptor(name: "ring")
        desc.positions = MeshBuffer(positions)
        desc.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [desc])) ?? MeshResource.generateBox(size: 0.01)
    }

    /// Called once from makeUIView. Creates the two overlay entities, hidden until needed.
    func installOverlays() {
        guard let arView else { return }

        // Reticle: a 12 cm ring, about the size of a cube
        let reticleRing = ModelEntity(mesh: Self.ringMesh(inner: 0.052, outer: 0.06),
                                      materials: [UnlitMaterial(color: .white)])
        let reticleAnchor = AnchorEntity(world: .zero)
        reticleAnchor.addChild(reticleRing)
        reticleAnchor.isEnabled = false
        arView.scene.addAnchor(reticleAnchor)
        reticle = reticleAnchor

        // Selection ring: radius 1, scaled to fit whichever object is selected
        let selectionColor = UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
        let ring = ModelEntity(mesh: Self.ringMesh(inner: 0.88, outer: 1.0),
                               materials: [UnlitMaterial(color: selectionColor)])
        let ringAnchor = AnchorEntity(world: .zero)
        ringAnchor.addChild(ring)
        ringAnchor.isEnabled = false
        arView.scene.addAnchor(ringAnchor)
        selectionRing = ringAnchor
    }

    /// Called every frame (60 Hz) from the AR session delegate.
    func updateFrame(_ frame: ARFrame, dt: Float) {
        updateGrab(dt: dt)
        updateReticle(frame: frame, dt: dt)
        updateSelection()
    }

    private func updateReticle(frame: ARFrame, dt: Float) {
        guard let arView, let reticle else { return }

        // 1. How good is tracking right now?
        var hit: ARRaycastResult?
        var newStatus: ScanStatus

        switch frame.camera.trackingState {
        case .normal:
            // 2. Tracking is fine: is there a surface under the middle of the screen?
            let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            hit = arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .horizontal).first
               ?? arView.raycast(from: center, allowing: .estimatedPlane, alignment: .horizontal).first

            // Ignore hits more than 3 m away: they are guesses and jitter badly
            if let h = hit {
                let c = frame.camera.transform.columns.3
                let p = h.worldTransform.columns.3
                let d = distance(SIMD3<Float>(c.x, c.y, c.z), SIMD3<Float>(p.x, p.y, p.z))
                if d > 3 { hit = nil }
            }
            newStatus = hit == nil ? .scanning : .ready

        case .limited(let reason):
            switch reason {
            case .initializing:       newStatus = .limited("starting up")
            case .excessiveMotion:    newStatus = .limited("slow down")
            case .insufficientFeatures: newStatus = .limited("low detail")
            case .relocalizing:       newStatus = .limited("relocalizing")
            @unknown default:         newStatus = .limited("")
            }

        case .notAvailable:
            newStatus = .limited("")
        }

        // Publishing 60 times a second would redraw the UI constantly, so only on change
        if status != newStatus { status = newStatus }

        // 3. Move the reticle onto the surface
        guard let hit else {
            reticle.isEnabled = false
            placementPosition = nil
            return
        }

        let m = hit.worldTransform
        let surface = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let lifted = surface + SIMD3<Float>(0, 0.003, 0)       // 3 mm up, so it doesn't z-fight the surface

        if reticle.isEnabled {
            let k = 1 - exp(-dt * 20)                           // glide instead of jitter
            reticle.position = reticle.position + (lifted - reticle.position) * k
        } else {
            reticle.position = lifted                           // first frame: snap, don't glide from the origin
        }
        reticle.orientation = Transform(matrix: m).rotation
        reticle.scale = SIMD3<Float>(repeating: 1 + 0.05 * sin(Float(frame.timestamp) * 4))   // gentle pulse
        reticle.isEnabled = true

        placementPosition = surface
    }

    private func updateSelection() {
        guard let selectionRing else { return }
        // The object may have been removed by undo, clear, or the object cap
        guard let body = selected, body.scene != nil else {
            selected = nil
            selectionRing.isEnabled = false
            return
        }

        // Put a ring on the ground under the object, sized to its footprint
        let b = body.visualBounds(relativeTo: nil)
        let radius = max(b.extents.x, b.extents.z) * 0.75 + 0.01
        selectionRing.position = SIMD3<Float>(b.center.x, b.center.y - b.extents.y / 2 + 0.004, b.center.z)
        selectionRing.scale = SIMD3<Float>(repeating: radius)
        selectionRing.isEnabled = true
    }

    // MARK: Spawning

    /// Called by a tap that isn't on an object. Places at the reticle, or warns if there's no surface.
    func placeAtReticle() {
        guard let position = placementPosition else {
            Haptics.warn()
            return
        }
        spawn(at: position)
    }

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

        // The visible mesh rides inside a physics wrapper, the same layout models use.
        // That lets the pop-in animation scale the visual without touching the physics body.
        let visual = ModelEntity(mesh: mesh, materials: [material])
        let body = ModelEntity()
        body.addChild(visual)
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

        // Pop in: the visual grows from almost nothing while the physics body falls
        if let visual = body.children.first { popIn(visual) }
        selected = body
        Haptics.place()

        spawned.append(anchor)
        if spawned.count > maxObjects { spawned.removeFirst().removeFromParent() }
        count = spawned.count
    }

    /// Shrinks an entity to 1% and animates it back to its real size. Scales its offset too,
    /// so a model whose centre was shifted onto the origin stays centred while it grows.
    private func popIn(_ entity: Entity) {
        let target = entity.transform
        var start = target
        start.scale = target.scale * 0.01
        start.translation = target.translation * 0.01
        entity.transform = start
        entity.move(to: target, relativeTo: entity.parent, duration: 0.28, timingFunction: .easeOut)
    }

    // MARK: Interaction

    /// The spawned object whose centre is closest to a screen point, within `radius` points.
    func object(near point: CGPoint, radius: CGFloat) -> ModelEntity? {
        guard let arView else { return nil }
        var best: ModelEntity?
        var bestDistance = radius
        for anchor in spawned {
            guard let body = anchor.children.first as? ModelEntity,
                  let p = arView.project(body.position(relativeTo: nil)) else { continue }
            let d = hypot(p.x - point.x, p.y - point.y)
            if d < bestDistance { best = body; bestDistance = d }
        }
        return best
    }

    func flick(_ body: ModelEntity) {
        guard let arView else { return }
        selected = body

        let z = arView.cameraTransform.matrix.columns.2
        var dir = -SIMD3<Float>(z.x, 0, z.z)
        dir = length(dir) < 0.01 ? SIMD3<Float>(0, 0, -1) : normalize(dir)
        dir += SIMD3<Float>(0, 0.6, 0)

        body.applyLinearImpulse(dir * 0.8, relativeTo: nil)
        body.applyAngularImpulse(SIMD3<Float>(Float.random(in: -0.004...0.004),
                                              Float.random(in: -0.004...0.004),
                                              Float.random(in: -0.004...0.004)),
                                 relativeTo: nil)
        Haptics.tap()
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

    func toggleHandTracking() {
        handTracking.toggle()
        if !handTracking { apply(nil) }
    }

    // MARK: Grabbing

    private func beginGrab(at point: CGPoint) {
        guard let arView else { return }

        // Pick the object whose centre is closest to the ring, within 90 points
        guard let body = object(near: point, radius: 90) else { return }

        // Keep the object at the distance it already is from the camera
        let cameraPos = arView.cameraTransform.translation
        grabDistance = min(max(distance(cameraPos, body.position(relativeTo: nil)), 0.25), 2.0)
        grabVelocity = .zero
        grabbed = body
        selected = body
        isHolding = true

        // Kinematic: moved by our code, ignores gravity
        body.physicsBody?.mode = .kinematic
        body.physicsMotion = PhysicsMotionComponent(linearVelocity: .zero, angularVelocity: .zero)
        Haptics.place()
    }

    /// Called every frame (60 Hz) from the AR session delegate.
    private func updateGrab(dt: Float) {
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
        Haptics.tap()
    }
}

// MARK: - Overlay (place button, popup, rail)

struct ControlOverlay: View {
    @ObservedObject var model: SceneModel
    @State private var showPicker = false
    @State private var confirmClear = false

    private var visibleModels: [String] {
        model.modelNames.filter { !ModelIcon.isHidden($0) }
    }

    private var currentSymbol: String {
        if case .primitive(let s) = model.choice { return s.icon }
        if case .usdz(let name) = model.choice { return ModelIcon.symbol(for: name) }
        return "plus"
    }

    private func setPicker(_ open: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showPicker = open }
        Haptics.tap()
    }

    var body: some View {
        ZStack {
            // Tap outside the popup to close it. While open, this also stops
            // stray taps from placing an object behind the popup.
            if showPicker {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { setPicker(false) }
            }

            // Top-right rail
            ActionRail(model: model, confirmClear: $confirmClear)
                .padding(.top, 8)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Bottom: popup, status, place button
            VStack(spacing: 12) {
                if showPicker {
                    PickerPopup(model: model, visibleModels: visibleModels) {
                        setPicker(false)
                    }
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                }
                StatusPill(count: model.count, hint: model.status.hint)
                PlaceButton(symbol: currentSymbol, isOpen: showPicker) {
                    setPicker(!showPicker)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .confirmationDialog("Remove all objects?",
                            isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Remove all", role: .destructive) {
                model.clear()
                Haptics.warn()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Place button + status

struct PlaceButton: View {
    let symbol: String
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 64, height: 64)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle().stroke(Color.white.opacity(isOpen ? 0.9 : 0.35),
                                    lineWidth: isOpen ? 2.5 : 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose what to place")
    }
}

struct StatusPill: View {
    let count: Int
    let hint: String

    var body: some View {
        Text("\(count) \(count == 1 ? "object" : "objects")  ·  \(hint)")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Picker popup

struct PickerPopup: View {
    @ObservedObject var model: SceneModel
    let visibleModels: [String]
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Shapes + models
            HStack(spacing: 8) {
                ForEach(SpawnShape.allCases) { s in
                    ChoiceChip(symbol: s.icon,
                               label: String(describing: s).capitalized,
                               selected: model.choice == .primitive(s)) {
                        model.choice = .primitive(s)
                        Haptics.select()
                        onPick()
                    }
                }
                if !visibleModels.isEmpty {
                    Divider().frame(height: 28)
                    ForEach(visibleModels, id: \.self) { name in
                        ChoiceChip(symbol: ModelIcon.symbol(for: name),
                                   label: name.replacingOccurrences(of: "_", with: " ").capitalized,
                                   selected: model.choice == .usdz(name)) {
                            model.choice = .usdz(name)
                            Haptics.select()
                            onPick()
                        }
                    }
                }
            }

            // Colors (popup stays open while picking)
            HStack(spacing: 8) {
                ForEach(model.palette.indices, id: \.self) { i in
                    let selected = model.colorIndex == i
                    Button {
                        model.colorIndex = i
                        Haptics.select()
                    } label: {
                        Circle()
                            .fill(model.palette[i])
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .padding(-5)
                                    .opacity(selected ? 1 : 0)
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color \(i + 1)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .opacity(model.usesColor ? 1 : 0.3)
            .allowsHitTesting(model.usesColor)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .frame(maxWidth: 360)
    }
}

struct ChoiceChip: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 48, height: 48)
                .background(selected ? Color.white.opacity(0.28) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Top-right rail

struct ActionRail: View {
    @ObservedObject var model: SceneModel
    @Binding var confirmClear: Bool

    var body: some View {
        VStack(spacing: 4) {
            RailButton(symbol: model.handTracking ? "hand.raised.fill" : "hand.raised",
                       label: "Hand tracking",
                       active: model.handTracking) {
                model.toggleHandTracking()
                Haptics.tap()
            }
            RailButton(symbol: model.showMesh ? "eye" : "eye.slash",
                       label: "Scene mesh",
                       active: model.showMesh) {
                model.showMesh.toggle()
                Haptics.tap()
            }
            RailButton(symbol: "arrow.uturn.backward",
                       label: "Undo",
                       enabled: model.count > 0) {
                model.undo()
                Haptics.tap()
            }
            RailButton(symbol: "trash",
                       label: "Clear all",
                       enabled: model.count > 0) {
                confirmClear = true
            }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct RailButton: View {
    let symbol: String
    let label: String
    var active = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background(active ? Color.white.opacity(0.25) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

// MARK: - AR view

struct ARContainer: UIViewRepresentable {
    @ObservedObject var model: SceneModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        model.arView = view
        model.installOverlays()
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
            // Per-frame work (60 Hz): held object, reticle, status, selection ring
            let dt = Float(min(max(frame.timestamp - lastTimestamp, 0.001), 0.1))
            lastTimestamp = frame.timestamp
            model.updateFrame(frame, dt: dt)

            // Hand detection runs separately, about 15 times a second
            guard model.handTracking, let view = model.arView else { return }
            tracker.process(frame: frame, viewSize: view.bounds.size) { [weak model] sample in
                model?.apply(sample)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = model.arView else { return }
            let point = gesture.location(in: view)

            // 1. A tap on or near an object flicks it. The 60 pt margin means a near miss
            //    flicks the object instead of dropping a new one on top of it.
            if let body = model.object(near: point, radius: 60) {
                model.flick(body)
                return
            }

            // 2. Anywhere else places at the reticle (or buzzes if there is no surface yet)
            model.placeAtReticle()
        }
    }
}
