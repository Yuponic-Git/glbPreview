#import "FBXSceneLoader.h"
#import <AppKit/AppKit.h>
#import "ufbx.h"

// The FBX reading follows Crayon's (crates/crayon-mesh/src/fbx.rs): the same ufbx options, PBR
// view of materials and texture search. What differs is the output: SceneKit nodes in world
// space, without the hierarchy, skins or clips a still preview has no use for.

/// What ufbx may allocate while reading one file (each of its two allocators).
static const size_t kMemoryLimit = (size_t)2 << 30;

/// How many folders down from the model, and how many entries in all, a texture is looked for.
static const NSUInteger kSearchDepth = 3;
static const NSUInteger kSearchLimit = 20000;

static NSString *const kErrorDomain = @"FBXSceneLoader";

typedef struct {
    float position[3];
    float normal[3];
    float uv[2];
    float color[4];
} FBXVertex;

static NSString *stringOf(ufbx_string s) {
    return [[NSString alloc] initWithBytes:s.data length:s.length encoding:NSUTF8StringEncoding] ?: @"";
}

static float srgbToLinear(float c) {
    return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}

/// A colour from linear values, which SceneKit lights in without converting again.
static NSColor *linearColor(float r, float g, float b, float a) {
    static NSColorSpace *space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGColorSpaceRef cg = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        space = [[NSColorSpace alloc] initWithCGColorSpace:cg];
        CGColorSpaceRelease(cg);
    });
    CGFloat components[4] = {r, g, b, a};
    return [NSColor colorWithColorSpace:space components:components count:4];
}

static float mapValue(const ufbx_material_map *map, float fallback) {
    return map->has_value ? (float)map->value_vec4.x : fallback;
}

static const ufbx_texture *mapTexture(const ufbx_material_map *map) {
    return map->texture_enabled ? map->texture : NULL;
}

/// The texture holding pixels: a layered texture's first file.
static const ufbx_texture *fileTexture(const ufbx_texture *t) {
    if (!t) return NULL;
    if (t->type == UFBX_TEXTURE_FILE) return t;
    return t->file_textures.count > 0 ? t->file_textures.data[0] : NULL;
}

static SCNMatrix4 matrixOf(ufbx_matrix m) {
    SCNMatrix4 r = SCNMatrix4Identity;
    r.m11 = m.m00; r.m12 = m.m10; r.m13 = m.m20;
    r.m21 = m.m01; r.m22 = m.m11; r.m23 = m.m21;
    r.m31 = m.m02; r.m32 = m.m12; r.m33 = m.m22;
    r.m41 = m.m03; r.m42 = m.m13; r.m43 = m.m23;
    return r;
}

@interface FBXSceneLoader ()
@property (nonatomic, copy, nullable) NSURL *directory;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *images;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, SCNMaterial *> *materials;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSURL *> *nearbyFiles;
@end

@implementation FBXSceneLoader

+ (SCNNode *)nodeWithContentsOfURL:(NSURL *)url error:(NSError **)error {
    ufbx_load_opts opts = {0};
    opts.temp_allocator.memory_limit = kMemoryLimit;
    opts.result_allocator.memory_limit = kMemoryLimit;
    opts.target_axes = ufbx_axes_right_handed_y_up;
    opts.target_unit_meters = 1.0;
    opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY;
    opts.geometry_transform_handling = UFBX_GEOMETRY_TRANSFORM_HANDLING_MODIFY_GEOMETRY;
    opts.inherit_mode_handling = UFBX_INHERIT_MODE_HANDLING_COMPENSATE;
    opts.generate_missing_normals = true;

    ufbx_error fbxError;
    ufbx_scene *scene = ufbx_load_file(url.fileSystemRepresentation, &opts, &fbxError);
    if (!scene) {
        if (error) {
            char message[512];
            ufbx_format_error(message, sizeof(message), &fbxError);
            *error = [NSError errorWithDomain:kErrorDomain code:1 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"This FBX file couldn't be read: %s", message]
            }];
        }
        return nil;
    }

    FBXSceneLoader *loader = [FBXSceneLoader new];
    loader.directory = url.URLByDeletingLastPathComponent;
    loader.images = [NSMutableDictionary dictionary];
    loader.materials = [NSMutableDictionary dictionary];
    SCNNode *root = [loader rootForScene:scene];
    ufbx_free_scene(scene);
    return root;
}

- (SCNNode *)rootForScene:(const ufbx_scene *)scene {
    SCNNode *root = [SCNNode node];
    NSMutableDictionary<NSNumber *, SCNGeometry *> *geometries = [NSMutableDictionary dictionary];
    for (size_t i = 0; i < scene->nodes.count; i++) {
        const ufbx_node *node = scene->nodes.data[i];
        if (!node->mesh || !node->visible) continue;
        NSNumber *key = @(node->mesh->element.typed_id);
        SCNGeometry *geometry = geometries[key];
        if (!geometry) {
            geometry = [self geometryForMesh:node->mesh];
            if (!geometry) continue;
            geometries[key] = geometry;
        }
        SCNNode *child = [SCNNode nodeWithGeometry:geometry];
        child.name = stringOf(node->element.name);
        child.transform = matrixOf(node->geometry_to_world);
        [root addChildNode:child];
    }
    return root;
}

/// Faces cut into triangles, one element per material, corners that share every attribute shared.
- (nullable SCNGeometry *)geometryForMesh:(const ufbx_mesh *)mesh {
    size_t cornerCount = mesh->num_triangles * 3;
    if (cornerCount == 0) return nil;

    size_t scratchCount = mesh->max_face_triangles * 3;
    uint32_t *scratch = malloc(scratchCount * sizeof(uint32_t));
    FBXVertex *vertices = malloc(cornerCount * sizeof(FBXVertex));
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSMutableArray<NSNumber *> *partMaterials = [NSMutableArray array];

    size_t cursor = 0;
    for (size_t p = 0; p < mesh->material_parts.count; p++) {
        const ufbx_mesh_part *part = &mesh->material_parts.data[p];
        if (part->num_triangles == 0) continue;
        size_t start = cursor;
        for (size_t f = 0; f < part->face_indices.count; f++) {
            ufbx_face face = mesh->faces.data[part->face_indices.data[f]];
            uint32_t triangles = ufbx_triangulate_face(scratch, scratchCount, mesh, face);
            for (size_t c = 0; c < triangles * 3 && cursor < cornerCount; c++) {
                uint32_t index = scratch[c];
                FBXVertex *v = &vertices[cursor++];
                ufbx_vec3 position = ufbx_get_vertex_vec3(&mesh->vertex_position, index);
                v->position[0] = (float)position.x;
                v->position[1] = (float)position.y;
                v->position[2] = (float)position.z;
                ufbx_vec3 normal = mesh->vertex_normal.exists ? ufbx_get_vertex_vec3(&mesh->vertex_normal, index) : (ufbx_vec3){0};
                v->normal[0] = (float)normal.x;
                v->normal[1] = (float)normal.y;
                v->normal[2] = (float)normal.z;
                ufbx_vec2 uv = mesh->vertex_uv.exists ? ufbx_get_vertex_vec2(&mesh->vertex_uv, index) : (ufbx_vec2){0};
                // FBX puts the texture's origin at the bottom; SceneKit at the top.
                v->uv[0] = (float)uv.x;
                v->uv[1] = 1.0f - (float)uv.y;
                ufbx_vec4 color = mesh->vertex_color.exists ? ufbx_get_vertex_vec4(&mesh->vertex_color, index) : (ufbx_vec4){{1, 1, 1, 1}};
                v->color[0] = srgbToLinear((float)color.x);
                v->color[1] = srgbToLinear((float)color.y);
                v->color[2] = srgbToLinear((float)color.z);
                v->color[3] = (float)color.w;
            }
        }
        if (cursor > start) {
            [ranges addObject:[NSValue valueWithRange:NSMakeRange(start, cursor - start)]];
            [partMaterials addObject:@(part->index)];
        }
    }
    free(scratch);

    uint32_t *indices = malloc(cursor * sizeof(uint32_t));
    ufbx_vertex_stream stream = {vertices, cursor, sizeof(FBXVertex)};
    ufbx_error indexError;
    size_t vertexCount = ufbx_generate_indices(&stream, 1, indices, cursor, NULL, &indexError);
    if (indexError.type != UFBX_ERROR_NONE || vertexCount == 0) {
        free(vertices);
        free(indices);
        return nil;
    }

    NSData *vertexData = [NSData dataWithBytesNoCopy:vertices length:vertexCount * sizeof(FBXVertex) freeWhenDone:YES];
    NSMutableArray<SCNGeometrySource *> *sources = [NSMutableArray arrayWithArray:@[
        [self sourceWithData:vertexData semantic:SCNGeometrySourceSemanticVertex count:vertexCount components:3 offset:offsetof(FBXVertex, position)],
        [self sourceWithData:vertexData semantic:SCNGeometrySourceSemanticNormal count:vertexCount components:3 offset:offsetof(FBXVertex, normal)],
        [self sourceWithData:vertexData semantic:SCNGeometrySourceSemanticTexcoord count:vertexCount components:2 offset:offsetof(FBXVertex, uv)],
    ]];
    // Low-poly kits often colour by vertex instead of by texture; SceneKit tints the material by it.
    if (mesh->vertex_color.exists) {
        [sources addObject:[self sourceWithData:vertexData semantic:SCNGeometrySourceSemanticColor count:vertexCount components:4 offset:offsetof(FBXVertex, color)]];
    }

    NSMutableArray<SCNGeometryElement *> *elements = [NSMutableArray array];
    NSMutableArray<SCNMaterial *> *materials = [NSMutableArray array];
    for (NSUInteger r = 0; r < ranges.count; r++) {
        NSRange range = ranges[r].rangeValue;
        NSData *indexData = [NSData dataWithBytes:indices + range.location length:range.length * sizeof(uint32_t)];
        [elements addObject:[SCNGeometryElement geometryElementWithData:indexData
                                                          primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                         primitiveCount:range.length / 3
                                                          bytesPerIndex:sizeof(uint32_t)]];
        uint32_t materialIndex = partMaterials[r].unsignedIntValue;
        const ufbx_material *material = materialIndex < mesh->materials.count ? mesh->materials.data[materialIndex] : NULL;
        [materials addObject:[self materialFor:material]];
    }
    free(indices);

    SCNGeometry *geometry = [SCNGeometry geometryWithSources:sources elements:elements];
    geometry.materials = materials;
    return geometry;
}

- (SCNGeometrySource *)sourceWithData:(NSData *)data semantic:(SCNGeometrySourceSemantic)semantic count:(size_t)count components:(NSInteger)components offset:(size_t)offset {
    return [SCNGeometrySource geometrySourceWithData:data
                                            semantic:semantic
                                         vectorCount:count
                                     floatComponents:YES
                                 componentsPerVector:components
                                   bytesPerComponent:sizeof(float)
                                          dataOffset:offset
                                          dataStride:sizeof(FBXVertex)];
}

#pragma mark - Materials

/// Through ufbx's PBR view of the material (Phong, Lambert, Stingray, 3ds Max Physical…).
- (SCNMaterial *)materialFor:(nullable const ufbx_material *)m {
    NSNumber *key = m ? @(m->element.typed_id) : @(UINT32_MAX);
    SCNMaterial *cached = self.materials[key];
    if (cached) return cached;

    SCNMaterial *material = [SCNMaterial material];
    material.lightingModelName = SCNLightingModelPhysicallyBased;
    self.materials[key] = material;
    if (!m) {
        material.diffuse.contents = linearColor(0.8f, 0.8f, 0.8f, 1.0f);
        return material;
    }
    material.name = stringOf(m->element.name);
    const ufbx_material_pbr_maps *pbr = &m->pbr;

    // Colours are read as sRGB, as three.js's FBX loader does.
    float factor = mapValue(&pbr->base_factor, 1.0f);
    ufbx_vec4 c = pbr->base_color.value_vec4;
    float alpha = pbr->base_color.value_components >= 4 ? (float)c.w : 1.0f;
    const ufbx_texture *baseTexture = fileTexture(mapTexture(&pbr->base_color));
    if ([self applyTexture:baseTexture to:material.diffuse]) {
        // A texture replaces FBX's colour; the factor still scales it.
        material.diffuse.intensity = factor;
    } else if (pbr->base_color.has_value) {
        material.diffuse.contents = linearColor(srgbToLinear((float)c.x) * factor, srgbToLinear((float)c.y) * factor, srgbToLinear((float)c.z) * factor, alpha);
    } else {
        material.diffuse.contents = linearColor(factor, factor, factor, alpha);
    }

    // A colour texture that is also the opacity texture cuts the shape out with its alpha, which
    // SceneKit reads from the diffuse texture on its own.
    float opacity = fminf(fmaxf(mapValue(&pbr->opacity, 1.0f), 0.0f), 1.0f);
    const ufbx_texture *opacityTexture = fileTexture(mapTexture(&pbr->opacity));
    if (!(opacityTexture && opacityTexture == baseTexture) && opacity < 0.999f) {
        material.transparency = opacity;
        material.blendMode = SCNBlendModeAlpha;
    }

    BOOL glossy = m->features.roughness_as_glossiness.enabled;
    float roughness = mapValue(&pbr->roughness, 0.5f);
    roughness = fminf(fmaxf(glossy ? 1.0f - roughness : roughness, 0.0f), 1.0f);
    if (glossy || ![self applyTexture:fileTexture(mapTexture(&pbr->roughness)) to:material.roughness]) {
        material.roughness.contents = @(roughness);
    }
    float metallic = fminf(fmaxf(mapValue(&pbr->metalness, 0.0f), 0.0f), 1.0f);
    if (![self applyTexture:fileTexture(mapTexture(&pbr->metalness)) to:material.metalness]) {
        material.metalness.contents = @(metallic);
    }

    const ufbx_texture *normal = mapTexture(&pbr->normal_map) ?: mapTexture(&m->fbx.normal_map);
    [self applyTexture:fileTexture(normal) to:material.normal];
    [self applyTexture:fileTexture(mapTexture(&pbr->ambient_occlusion)) to:material.ambientOcclusion];

    // Emission is its colour times its strength; a texture takes the colour's place.
    float strength = mapValue(&pbr->emission_factor, 1.0f);
    if ([self applyTexture:fileTexture(mapTexture(&pbr->emission_color)) to:material.emission]) {
        material.emission.intensity = strength;
    } else if (pbr->emission_color.has_value) {
        ufbx_vec4 e = pbr->emission_color.value_vec4;
        material.emission.contents = linearColor(srgbToLinear((float)e.x) * strength, srgbToLinear((float)e.y) * strength, srgbToLinear((float)e.z) * strength, 1.0f);
    }
    material.doubleSided = m->features.double_sided.enabled;
    return material;
}

- (BOOL)applyTexture:(nullable const ufbx_texture *)texture to:(SCNMaterialProperty *)property {
    NSImage *image = texture ? [self imageFor:texture] : nil;
    if (!image) return NO;
    property.contents = image;
    property.wrapS = texture->wrap_u == UFBX_WRAP_CLAMP ? SCNWrapModeClamp : SCNWrapModeRepeat;
    property.wrapT = texture->wrap_v == UFBX_WRAP_CLAMP ? SCNWrapModeClamp : SCNWrapModeRepeat;
    property.mipFilter = SCNFilterModeLinear;
    return YES;
}

/// Each texture's image, decoded once.
- (nullable NSImage *)imageFor:(const ufbx_texture *)texture {
    NSNumber *key = @(texture->element.typed_id);
    id cached = self.images[key];
    if (cached) return cached == [NSNull null] ? nil : cached;
    NSData *data = [self bytesOf:texture];
    NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
    self.images[key] = image ?: [NSNull null];
    return image;
}

/// A texture's bytes: embedded in the file, or a file near it: by its relative path, then by its
/// name alone in the model's folder or the folders under it (FBX files keep the path on the
/// machine that wrote them, and game projects keep textures in a folder of their own).
- (nullable NSData *)bytesOf:(const ufbx_texture *)texture {
    if (texture->content.size > 0) {
        return [NSData dataWithBytes:texture->content.data length:texture->content.size];
    }
    if (texture->video && texture->video->content.size > 0) {
        return [NSData dataWithBytes:texture->video->content.data length:texture->video->content.size];
    }
    if (!self.directory) return nil;
    NSString *relative = [stringOf(texture->relative_filename) stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSString *full = [stringOf(texture->filename) stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (relative.length > 0) {
        NSData *data = [NSData dataWithContentsOfURL:[self.directory URLByAppendingPathComponent:relative]];
        if (data) return data;
    }
    for (NSString *name in @[relative.lastPathComponent, full.lastPathComponent]) {
        NSURL *url = name.length > 0 ? self.nearbyFiles[name.lowercaseString] : nil;
        NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
        if (data) return data;
    }
    return nil;
}

/// The files in the model's folder and the folders under it, by lowercased name (Windows paths
/// disagree on case). Listed once, on the first texture that needs it; the shallowest file of a
/// name wins.
- (NSDictionary<NSString *, NSURL *> *)nearbyFiles {
    if (_nearbyFiles) return _nearbyFiles;
    NSMutableDictionary<NSString *, NSURL *> *files = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *depths = [NSMutableDictionary dictionary];
    NSDirectoryEnumerator<NSURL *> *walk = [NSFileManager.defaultManager enumeratorAtURL:self.directory
                                                              includingPropertiesForKeys:nil
                                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants
                                                                            errorHandler:nil];
    NSUInteger seen = 0;
    for (NSURL *url in walk) {
        if (++seen > kSearchLimit) break;
        if (walk.level >= kSearchDepth) [walk skipDescendants];
        NSString *key = url.lastPathComponent.lowercaseString;
        NSNumber *depth = depths[key];
        if (!depth || depth.unsignedIntegerValue > walk.level) {
            files[key] = url;
            depths[key] = @(walk.level);
        }
    }
    _nearbyFiles = files;
    return files;
}

@end
