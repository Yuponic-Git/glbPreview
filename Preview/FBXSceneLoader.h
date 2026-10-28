#import <SceneKit/SceneKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads an FBX file (binary or text) through ufbx into a SceneKit node: Y up, metres, each mesh
/// placed by its world transform, materials through ufbx's PBR view of them. Rest pose only.
@interface FBXSceneLoader : NSObject

+ (nullable SCNNode *)nodeWithContentsOfURL:(NSURL *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
