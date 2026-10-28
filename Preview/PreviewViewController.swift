import Cocoa
import Quartz
import SceneKit

/// The Quick Look preview: the model on a dark stage, lit and framed as AIART's SceneKit viewer
/// does, turned with the mouse.
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let sceneView = SCNView()
    private let scene = SCNScene()
    private let cameraNode = SCNNode()

    /// The model is scaled so its largest side is this long.
    private let modelSize: CGFloat = 1.5

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        sceneView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        sceneView.autoresizingMask = [.width, .height]
        sceneView.backgroundColor = NSColor(white: 0.1, alpha: 1)
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = false
        sceneView.antialiasingMode = .multisampling4X
        sceneView.scene = scene
        scene.background.contents = NSColor(white: 0.1, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 1000
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode

        addLight(.ambient, intensity: 800, at: nil)
        addLight(.directional, intensity: 1200, at: SCNVector3(5, 5, 5))
        addLight(.directional, intensity: 400, at: SCNVector3(-3, 2, -3))

        view = sceneView
        preferredContentSize = sceneView.frame.size
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ModelLoader.node(contentsOf: url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let model):
                    self.show(model)
                    handler(nil)
                case .failure(let error):
                    handler(error)
                }
            }
        }
    }

    private func addLight(_ type: SCNLight.LightType, intensity: CGFloat, at position: SCNVector3?) {
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = NSColor.white
        let node = SCNNode()
        node.light = light
        if let position {
            node.position = position
            node.look(at: SCNVector3Zero)
        }
        scene.rootNode.addChildNode(node)
    }

    /// Centres the model on the origin at `modelSize`, then backs the camera off until it fits.
    private func show(_ model: SCNNode) {
        let holder = SCNNode()
        holder.addChildNode(model)
        let (low, high) = holder.boundingBox
        let size = SCNVector3(high.x - low.x, high.y - low.y, high.z - low.z)
        let largest = max(size.x, size.y, size.z)
        let scale = largest > 0 ? modelSize / largest : 1
        let center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        holder.scale = SCNVector3(scale, scale, scale)
        holder.position = SCNVector3(-center.x * scale, -center.y * scale, -center.z * scale)
        scene.rootNode.addChildNode(holder)

        let fov = (cameraNode.camera?.fieldOfView ?? 60) * .pi / 180
        let distance = (modelSize / 2) / tan(fov / 2) * 1.4
        let direction = SCNVector3(0, 1, 3)
        let length = sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
        cameraNode.position = SCNVector3(direction.x / length * distance, direction.y / length * distance, direction.z / length * distance)
        cameraNode.look(at: SCNVector3Zero)
        sceneView.defaultCameraController.target = SCNVector3Zero
    }
}
