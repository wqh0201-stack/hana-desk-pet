import CoreGraphics
import Foundation
import ImageIO

public enum PetArtworkCatalogError: Error, Equatable {
    case directoryUnavailable
    case catalogUnavailable
    case invalidCatalog
    case assetUnavailable(characterID: String, filename: String)
}

public enum PetArtworkPoseMapper {
    public static func poseName(for status: PetActivityStatus, animationStep: Int) -> String {
        switch status {
        case .idle:
            if animationStep % 13 == 8 { return "idle-blink" }
            return ["idle", "idle-2", "idle-3"][(animationStep / 2) % 3]
        case .working:
            return animationStep % 2 == 0 ? "thinking" : "writing"
        case .tool:
            return animationStep % 2 == 0 ? "busy_left" : "busy_right"
        case .success:
            return "happy"
        case .error:
            return "oops"
        }
    }
}

private struct ArtworkCatalogDocument: Decodable {
    let schemaVersion: Int
    let characters: [ArtworkCharacter]
}

private struct ArtworkCharacter: Decodable {
    let id: String
    let assetDirectory: String
    let poseFiles: [String]
}

/// A decoded, single-frame character image with a pixel-accurate alpha hit mask.
public final class PetArtworkFrame: NSObject {
    public let image: CGImage
    public let width: Int
    public let height: Int
    public let byteCost: Int
    private let alphaBytes: Data
    private let bytesPerRow: Int
    private let alphaOffset: Int

    fileprivate init?(image: CGImage) {
        guard image.bitsPerPixel == 32,
              let provider = image.dataProvider,
              let providerData = provider.data else { return nil }
        switch image.alphaInfo {
        case .last, .premultipliedLast:
            alphaOffset = 3
        case .first, .premultipliedFirst:
            alphaOffset = 0
        default:
            return nil
        }
        let data = providerData as Data
        guard data.count >= image.bytesPerRow * image.height else { return nil }
        self.image = image
        self.width = image.width
        self.height = image.height
        self.bytesPerRow = image.bytesPerRow
        self.alphaBytes = data
        self.byteCost = data.count * 2
    }

    /// Raw source alpha for one pixel (0–255), top-left origin, independent of AppKit view
    /// coordinates. Reads the already-decoded mask, so a hit test never decodes an image.
    /// Out-of-bounds reads report fully transparent instead of trapping.
    public func alphaValue(x: Int, yFromTop: Int) -> UInt8 {
        guard x >= 0, x < width, yFromTop >= 0, yFromTop < height else { return 0 }
        return alphaBytes[yFromTop * bytesPerRow + x * 4 + alphaOffset]
    }

    public func containsOpaquePixel(x: Int, yFromTop: Int, minimumAlpha: UInt8 = 16) -> Bool {
        alphaValue(x: x, yFromTop: yFromTop) >= minimumAlpha
    }
}

/// Loads only the catalog-listed, original WebP poses from a bundled or test-supplied directory.
public final class PetArtworkCatalog {
    private let directoryURL: URL
    private let charactersByID: [String: ArtworkCharacter]
    private let maximumAspectRatioCache: Double
    private let frameCache = NSCache<NSString, PetArtworkFrame>()

    /// Largest catalog-listed source-image width/height ratio, read from image headers once at initialization.
    public var maximumAspectRatio: Double { maximumAspectRatioCache }

    public init(directoryURL: URL) throws {
        let directory = directoryURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PetArtworkCatalogError.directoryUnavailable
        }
        let catalogURL = directory.appendingPathComponent("catalog.json", isDirectory: false)
        guard let data = try? Data(contentsOf: catalogURL),
              let document = try? JSONDecoder().decode(ArtworkCatalogDocument.self, from: data),
              document.schemaVersion == 1,
              document.characters.map(\.id) == PetRole.builtIns.map(\.id) else {
            throw PetArtworkCatalogError.catalogUnavailable
        }

        var entries: [String: ArtworkCharacter] = [:]
        for character in document.characters {
            guard character.assetDirectory == character.id,
                  !character.poseFiles.isEmpty,
                  character.poseFiles.contains("idle.webp"),
                  Set(character.poseFiles).count == character.poseFiles.count,
                  character.poseFiles.allSatisfy(Self.isSafePoseFilename),
                  entries[character.id] == nil else {
                throw PetArtworkCatalogError.invalidCatalog
            }
            entries[character.id] = character
        }
        guard entries.count == PetRole.builtIns.count else {
            throw PetArtworkCatalogError.invalidCatalog
        }
        self.directoryURL = directory
        self.charactersByID = entries
        self.maximumAspectRatioCache = Self.maximumAspectRatio(directoryURL: directory, characters: entries)
        frameCache.countLimit = 16
        frameCache.totalCostLimit = 32 * 1024 * 1024
    }

    public func poseNames(forCharacterID characterID: String) -> [String] {
        charactersByID[characterID]?.poseFiles.map { String($0.dropLast(".webp".count)) } ?? []
    }

    @discardableResult
    public func validateAllAssets() throws -> Int {
        var decodedCount = 0
        for role in PetRole.builtIns {
            guard let character = charactersByID[role.id] else {
                throw PetArtworkCatalogError.invalidCatalog
            }
            for filename in character.poseFiles {
                guard decodeFrame(character: character, filename: filename) != nil else {
                    throw PetArtworkCatalogError.assetUnavailable(characterID: character.id, filename: filename)
                }
                decodedCount += 1
            }
        }
        return decodedCount
    }

    public func frame(characterID: String, poseName: String) -> PetArtworkFrame? {
        guard let character = charactersByID[characterID] else { return nil }
        let available = Set(character.poseFiles)
        let requestedFilename = "\(poseName).webp"
        let resolvedFilename: String
        if available.contains(requestedFilename) {
            resolvedFilename = requestedFilename
        } else if poseName == "happy", available.contains("happy-2.webp") {
            // Claude's listed success artwork uses the upstream happy-2 filename.
            resolvedFilename = "happy-2.webp"
        } else {
            resolvedFilename = "idle.webp"
        }

        if let cached = cachedFrame(characterID: characterID, filename: resolvedFilename) {
            return cached
        }
        guard let decoded = decodeFrame(character: character, filename: resolvedFilename) else {
            guard resolvedFilename != "idle.webp" else { return nil }
            return frame(characterID: characterID, poseName: "idle")
        }
        frameCache.setObject(decoded, forKey: cacheKey(characterID: characterID, filename: resolvedFilename), cost: decoded.byteCost)
        return decoded
    }

    private func cachedFrame(characterID: String, filename: String) -> PetArtworkFrame? {
        frameCache.object(forKey: cacheKey(characterID: characterID, filename: filename))
    }

    private func cacheKey(characterID: String, filename: String) -> NSString {
        "\(characterID)/\(filename)" as NSString
    }

    private static func maximumAspectRatio(directoryURL: URL, characters: [String: ArtworkCharacter]) -> Double {
        var maximum = 0.0
        for character in characters.values {
            for filename in character.poseFiles {
                let imageURL = directoryURL
                    .appendingPathComponent(character.assetDirectory, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                      width > 0, height > 0 else { continue }
                maximum = max(maximum, width / height)
            }
        }
        return maximum > 0 ? maximum : 1.0
    }

    private func decodeFrame(character: ArtworkCharacter, filename: String) -> PetArtworkFrame? {
        guard character.poseFiles.contains(filename) else { return nil }
        let imageURL = directoryURL
            .appendingPathComponent(character.assetDirectory, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return PetArtworkFrame(image: image)
    }

    private static func isSafePoseFilename(_ filename: String) -> Bool {
        guard filename.hasSuffix(".webp"), filename.count > ".webp".count else { return false }
        let stem = filename.dropLast(".webp".count)
        return stem.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) ||
            scalar.value == 45 || scalar.value == 95
        }
    }
}
