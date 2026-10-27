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

private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

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

    private var selected: ModelEntity?

    // GLOW: the object the hand is pointing at, and one glow per object that has been pointed at
    private var hovered: ModelEntity?
    private var glows: [ObjectIdentifier: HoverGlow] = [:]

    // Grabbing
    private var grabbed: ModelEntity?
    private var grabPoint: CGPoint = .zero          // ring position on screen
    private var grabDistance: Float = 0.6           // metres from the camera
    private var grabVelocity = SIMD3<Float>.zero    // smoothed, for throwing
    private static let throwEnabled = false         // false: letting go just lets the object settle

    var usesColor: Bool {
        if case .primitive = choice { return true }
        return false
    }

    /// Kept so ARContainer's call still compiles. Nothing to install now that the ring is gone.
    func installOverlays() {}

    /// Called every frame (60 Hz) from the AR session delegate.
    func updateFrame(_ frame: ARFrame, dt: Float) {
        updateGrab(dt: dt)
        updateGlows(dt: dt)            // GLOW
    }

    func select(_ body: ModelEntity) {
        selected = body
        Haptics.select()
    }

    // MARK: Spawning

    /// A tap that isn't on an object: raycast to a surface at the finger and place there.
    func place(at point: CGPoint) {
        guard let arView else { return }
        let hit = arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .horizontal).first
               ?? arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else {
            Haptics.warn()
            return
        }
        let t = hit.worldTransform.columns.3
        spawn(at: SIMD3<Float>(t.x, t.y, t.z))
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
            material: .generate(friction: 0.8, restitution: 0.05),   // grippy, almost no bounce
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

        // Appear exactly where you tapped: the object's lowest point rests 5 mm above the surface
        // (measured before the pop-in shrinks it), no height, no tilt
        let b = body.visualBounds(relativeTo: body)
        body.position.y = -b.min.y + 0.005

        let anchor = AnchorEntity(world: position)
        anchor.addChild(body)
        arView.scene.addAnchor(anchor)

        // Pop in: the visual grows from almost nothing
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

    /// Not used right now (a tap selects instead). Kept so it can be switched back on.
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
        guard let sample else {
            endGrab(throwing: false)
            hovered = nil                                  // GLOW
            return
        }

        let mid = CGPoint(x: (sample.thumb.x + sample.index.x) / 2,
                          y: (sample.thumb.y + sample.index.y) / 2)

        if sample.pinching {
            // Only a pinch that *starts* near an object grabs it
            if grabbed == nil && !wasPinching { beginGrab(at: mid) }
            grabPoint = mid
        } else {
            endGrab(throwing: true)
        }

        updateHover(at: mid)                               // GLOW
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

    /// Called every frame (60 Hz) from updateFrame.
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

        var velocity: SIMD3<Float> = (throwing && Self.throwEnabled) ? grabVelocity : .zero
        let speed = length(velocity)
        if speed > 4 { velocity *= 4 / speed }   // clamp at 4 m/s

        body.physicsBody?.mode = .dynamic
        body.physicsMotion = PhysicsMotionComponent(linearVelocity: velocity, angularVelocity: .zero)
        Haptics.tap()
    }

    // MARK: GLOW (hover and grab feedback for hand tracking)
    // To remove the feature: delete this section, the HoverGlow class below, and the lines marked GLOW.

    /// Picks which object the hand is pointing at. Runs at the 15 Hz hand-detection rate.
    private func updateHover(at point: CGPoint) {
        // Holding something: that is the glowing object
        if let held = grabbed { hovered = held; return }

        // Pinching with nothing in hand (the pinch started away from an object): no glow
        if isPinching { hovered = nil; return }

        // Hysteresis: stay on the current target until the hand is 120 pt away,
        // but only pick a new one inside 90 pt, so the glow doesn't flicker at the edge
        if let current = hovered, current.scene != nil,
           let p = arView?.project(current.position(relativeTo: nil)),
           hypot(p.x - point.x, p.y - point.y) < 120 {
            return
        }
        hovered = object(near: point, radius: 90)
    }

    /// Runs every frame so the glow fades smoothly between the 15 Hz hand updates.
    private func updateGlows(dt: Float) {
        // Build an object's glow the first time the hand points at it
        if let h = hovered, h.scene != nil, glows[ObjectIdentifier(h)] == nil {
            glows[ObjectIdentifier(h)] = HoverGlow(for: h)
        }

        for (id, glow) in glows {
            guard let body = glow.body, body.scene != nil else {
                glows[id] = nil                           // the object was removed
                continue
            }
            glow.update(hovering: body === hovered, holding: body === grabbed, dt: dt)
        }
    }
}

// MARK: - HoverGlow

/// A soft glow around one object, made of two slightly larger copies of it (shells).
/// Only the shells' back faces are drawn, so the real object hides the middle and what
/// shows is a rim around its silhouette. Hovering = wide, faint rim. Holding = tight, nearly solid.
final class HoverGlow {
    weak var body: ModelEntity?

    private let outer: Entity
    private let inner: Entity
    private let outerParts: [Entity]
    private let innerParts: [Entity]
    private let half: SIMD3<Float>      // half the object's size, used to give the rim an even thickness
    private var hover: Float = 0        // 0...1, how visible the glow is
    private var hold: Float = 0         // 0...1, how much it has tightened toward a grab

    private static let cool: (Float, Float, Float) = (0.72, 0.88, 1.00)   // hovering: cool white
    private static let warm: (Float, Float, Float) = (1.00, 0.62, 0.20)   // holding: orange, like the hand ring

    init?(for body: ModelEntity) {
        guard let visual = body.children.first else { return nil }
        self.body = body

        let b = body.visualBounds(relativeTo: body)
        half = SIMD3<Float>(max(b.extents.x / 2, 0.01),
                            max(b.extents.y / 2, 0.01),
                            max(b.extents.z / 2, 0.01))

        let o = Self.makeShell(copying: visual, into: body)
        let i = Self.makeShell(copying: visual, into: body)
        outer = o.shell
        outerParts = o.parts
        inner = i.shell
        innerParts = i.parts
    }

    /// Copies the object's visual into a hidden wrapper, and lists every part that has a mesh.
    private static func makeShell(copying source: Entity, into parent: Entity) -> (shell: Entity, parts: [Entity]) {
        let shell = Entity()
        let copy = source.clone(recursive: true)
        shell.addChild(copy)
        parent.addChild(shell)
        shell.isEnabled = false

        var parts: [Entity] = []
        func collect(_ e: Entity) {
            if e.components[ModelComponent.self] != nil { parts.append(e) }
            for child in e.children { collect(child) }
        }
        collect(copy)
        return (shell, parts)
    }

    private static func material(red: Float, green: Float, blue: Float, alpha: Float) -> UnlitMaterial {
        var m = UnlitMaterial(color: UIColor(red: CGFloat(red), green: CGFloat(green),
                                             blue: CGFloat(blue), alpha: 1))
        m.faceCulling = .front                                           // draw only the back faces
        m.blending = .transparent(opacity: .init(floatLiteral: alpha))   // see-through
        return m
    }

    func update(hovering: Bool, holding: Bool, dt: Float) {
        // Fade in fast (about 150 ms), out slower (about 250 ms)
        let active = hovering || holding
        let rate = 1 - exp(-dt * (active ? 14 : 8))
        hover += ((active ? 1 : 0) - hover) * rate
        hold += ((holding ? 1 : 0) - hold) * rate

        guard hover > 0.01 else {
            outer.isEnabled = false
            inner.isEnabled = false
            return
        }
        outer.isEnabled = true
        inner.isEnabled = true

        let c = Self.cool, w = Self.warm
        let r = lerp(c.0, w.0, hold), g = lerp(c.1, w.1, hold), b = lerp(c.2, w.2, hold)

        // Hover: wide and faint. Hold: tight and nearly solid.
        apply(to: outer, parts: outerParts,
              thickness: lerp(0.014, 0.008, hold), alpha: lerp(0.20, 0.40, hold) * hover,
              red: r, green: g, blue: b)
        apply(to: inner, parts: innerParts,
              thickness: lerp(0.007, 0.0035, hold), alpha: lerp(0.35, 0.92, hold) * hover,
              red: r, green: g, blue: b)
    }

    private func apply(to shell: Entity, parts: [Entity], thickness t: Float, alpha: Float,
                       red: Float, green: Float, blue: Float) {
        // Per-axis scale so the rim is about `t` metres thick on every side
        shell.scale = SIMD3<Float>(1 + t / half.x, 1 + t / half.y, 1 + t / half.z)

        let m = Self.material(red: red, green: green, blue: blue, alpha: alpha)
        for part in parts {
            guard var model = part.components[ModelComponent.self] else { continue }
            model.materials = Array(repeating: m, count: max(model.materials.count, 1))
            part.components.set(model)
        }
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

// MARK: - Place button

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
            // Per-frame work (60 Hz): held object, status hint, glow, selection ring
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

            // 1. A tap on or near an object selects it. The 60 pt margin means a near miss
            //    selects the object instead of placing a new one on top of it.
            if let body = model.object(near: point, radius: 60) {
                model.select(body)
                return
            }

            // 2. Anywhere else: the object appears where you tapped
            model.place(at: point)
        }
    }
}
