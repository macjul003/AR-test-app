import SwiftUI
import ARKit
import Vision

struct HandSample {
    var thumb: CGPoint      // screen points
    var index: CGPoint
    var pinching: Bool
}

final class HandTracker {
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private let queue = DispatchQueue(label: "hand.vision", qos: .userInteractive)

    // Touched only on the main thread
    private var busy = false
    private var lastRun: TimeInterval = 0
    // Touched only on `queue`
    private var pinching = false

    /// Call from the ARSession delegate (main thread). Completion runs on the main thread.
    func process(frame: ARFrame, viewSize: CGSize, completion: @escaping (HandSample?) -> Void) {
        guard !busy, frame.timestamp - lastRun > 1.0 / 15.0 else { return }
        busy = true
        lastRun = frame.timestamp

        // Grab what we need now; don't hold on to the ARFrame itself
        let buffer = frame.capturedImage
        let transform: CGAffineTransform
        if #available(iOS 27.0, *) {
            // 90 = portrait (0 landscape-right, 180 landscape-left, 270 upside-down)
            transform = frame.displayTransform(viewRotationAngle: 90, viewportSize: viewSize)
        } else {
            transform = frame.displayTransform(for: .portrait, viewportSize: viewSize)
        }

        queue.async { [self] in
            let sample = detect(buffer: buffer, transform: transform, viewSize: viewSize)
            DispatchQueue.main.async { [self] in
                self.busy = false
                completion(sample)
            }
        }
    }

    private func detect(buffer: CVPixelBuffer, transform: CGAffineTransform, viewSize: CGSize) -> HandSample? {
        // .right tells Vision the sensor image must be rotated to be upright (portrait)
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first,
              let thumb = try? obs.recognizedPoint(.thumbTip),
              let index = try? obs.recognizedPoint(.indexTip),
              let wrist = try? obs.recognizedPoint(.wrist),
              let mcp = try? obs.recognizedPoint(.middleMCP),
              [thumb, index, wrist, mcp].allSatisfy({ $0.confidence > 0.4 })
        else {
            pinching = false
            return nil
        }

        // Vision (upright, origin bottom-left) -> camera buffer (origin top-left)
        // -> screen points via ARKit's display transform (handles rotation + aspect-fill crop)
        func screenPoint(_ p: VNRecognizedPoint) -> CGPoint {
            let buffer = CGPoint(x: 1 - p.y, y: 1 - p.x)
            let n = buffer.applying(transform)
            return CGPoint(x: n.x * viewSize.width, y: n.y * viewSize.height)
        }

        let t = screenPoint(thumb), i = screenPoint(index)
        let w = screenPoint(wrist), m = screenPoint(mcp)

        // Pinch = thumb-index gap relative to palm size, with hysteresis
        let palm = hypot(w.x - m.x, w.y - m.y)
        let gap = hypot(t.x - i.x, t.y - i.y)
        let ratio = palm > 1 ? gap / palm : 1
        pinching = pinching ? (ratio < 0.5) : (ratio < 0.3)

        return HandSample(thumb: t, index: i, pinching: pinching)
    }
}

/// Overlay: dots on the fingertips, a ring between them.
/// White = open, green = pinching, orange = holding an object.
struct HandCursor: View {
    @ObservedObject var model: SceneModel

    var body: some View {
        ZStack {
            Color.clear
            if let t = model.thumbPoint, let i = model.indexPoint {
                let mid = CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
                let tint: Color = model.isHolding ? .orange : (model.isPinching ? .green : .white)

                Circle().fill(.white).frame(width: 10, height: 10).position(t)
                Circle().fill(.white).frame(width: 10, height: 10).position(i)
                Circle()
                    .strokeBorder(tint, lineWidth: 3)
                    .background(Circle().fill(tint.opacity(0.25)))
                    .frame(width: model.isPinching ? 28 : 44, height: model.isPinching ? 28 : 44)
                    .position(mid)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)   // taps pass through to the AR view
    }
}
