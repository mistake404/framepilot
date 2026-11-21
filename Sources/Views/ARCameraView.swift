import SwiftUI
import ARKit
import SceneKit

struct ARCameraView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.rendersMotionBlur = false
        view.contentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
