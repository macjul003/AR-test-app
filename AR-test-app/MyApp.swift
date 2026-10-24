import SwiftUI
import RealityKit
import ARKit

struct ContentView: View {
    var body: some View {
        ARContainer().ignoresSafeArea()
    }
}

struct ARContainer: UIViewRepresentable {
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)

        context.coordinator.view = view
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: context.coordinator,
                                   action: #selector(Coordinator.handleTap(_:)))
        )
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject {
        weak var view: ARView?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            guard let hit = view.raycast(from: point,
                                         allowing: .estimatedPlane,
                                         alignment: .horizontal).first else { return }

            let box = ModelEntity(
                mesh: .generateBox(size: 0.1, cornerRadius: 0.005),
                materials: [SimpleMaterial(color: .systemBlue, isMetallic: true)]
            )
            box.position.y = 0.05   // lift so it sits on the surface, not half-buried

            let anchor = AnchorEntity(raycastResult: hit)
            anchor.addChild(box)
            view.scene.addAnchor(anchor)
        }
    }
}
