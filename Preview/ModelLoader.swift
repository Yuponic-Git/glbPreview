import Foundation
import GLTFKit2
import SceneKit

/// Turns a 3D file into a SceneKit node. The format comes from the file's first bytes, not its
/// name: FAL's Tripo can return FBX named `.glb` (the same rule as Crayon's `format::sniff`).
enum ModelLoader {
    enum Format {
        case glb, gltf, fbx
    }

    struct UnreadableFile: LocalizedError {
        var errorDescription: String? { "This file is not a GLB, glTF or FBX model." }
    }

    static func node(contentsOf url: URL) throws -> SCNNode {
        switch format(of: url) {
        case .glb, .gltf:
            let asset = try GLTFAsset(url: url)
            guard let scene = GLTFSCNSceneSource(asset: asset).defaultScene else { throw UnreadableFile() }
            return scene.rootNode
        case .fbx:
            return try FBXSceneLoader.node(withContentsOf: url)
        case nil:
            throw UnreadableFile()
        }
    }

    static func format(of url: URL) -> Format? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        if head.starts(with: Data("glTF".utf8)) { return .glb }
        if head.starts(with: Data("Kaydara FBX Binary".utf8)) { return .fbx }
        let text = String(decoding: head, as: UTF8.self)
        let trimmed = text.drop { $0 == "\u{feff}" || $0.isWhitespace }
        if trimmed.hasPrefix("; FBX") || trimmed.hasPrefix("FBXHeaderExtension") { return .fbx }
        if trimmed.hasPrefix("{") && text.contains("\"asset\"") { return .gltf }
        return nil
    }
}
