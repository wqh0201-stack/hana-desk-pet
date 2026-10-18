import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

// A build tool for macOS. The Windows app consumes PNG and never needs a WebP codec.
// Only the checked-in catalog is an input; no directory scan can add a character.
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func readImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0,
          image.width <= 4096, image.height <= 4096 else {
        throw NSError(domain: "WindowsAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid single-frame image: \(url.lastPathComponent)"])
    }
    return image
}

private func rgba(_ image: CGImage) throws -> Data {
    var pixels = Data(count: image.width * image.height * 4)
    let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return false }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard success else { throw NSError(domain: "WindowsAssets", code: 2) }
    return pixels
}

private func png(_ image: CGImage) throws -> Data {
    let bytes = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "WindowsAssets", code: 3)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "WindowsAssets", code: 4) }
    return bytes as Data
}

private func icon(_ source: CGImage) throws -> Data {
    let sizes = [16, 32, 48, 64, 128, 256]
    var frames: [Data] = []
    for size in sizes {
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "WindowsAssets", code: 5) }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let frame = context.makeImage() else { throw NSError(domain: "WindowsAssets", code: 6) }
        frames.append(try png(frame))
    }
    var output = Data()
    func u16(_ value: Int) { var number = UInt16(value).littleEndian; output.append(Data(bytes: &number, count: 2)) }
    func u32(_ value: Int) { var number = UInt32(value).littleEndian; output.append(Data(bytes: &number, count: 4)) }
    u16(0); u16(1); u16(sizes.count)
    var offset = 6 + 16 * sizes.count
    for (index, size) in sizes.enumerated() {
        output.append(contentsOf: [size == 256 ? 0 : UInt8(size), size == 256 ? 0 : UInt8(size), 0, 0])
        u16(1); u16(32); u32(frames[index].count); u32(offset)
        offset += frames[index].count
    }
    for frame in frames { output.append(frame) }
    return output
}

guard CommandLine.arguments.count == 4 else {
    fail("Usage: prepare-windows-assets <catalog-directory> <icon.png> <new-output-directory>")
}
let sourceRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let iconURL = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let outputRoot = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true).standardizedFileURL
let manager = FileManager.default
guard !manager.fileExists(atPath: outputRoot.path) else { fail("Refusing to overwrite output directory: \(outputRoot.path)") }

do {
    let catalogData = try Data(contentsOf: sourceRoot.appendingPathComponent("catalog.json"))
    guard var document = try JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
          document["schemaVersion"] as? Int == 1,
          var characters = document["characters"] as? [[String: Any]],
          characters.compactMap({ $0["id"] as? String }) == ["claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"] else {
        fail("Invalid source catalog")
    }
    let artworkRoot = outputRoot.appendingPathComponent("CrossPet", isDirectory: true)
    try manager.createDirectory(at: artworkRoot, withIntermediateDirectories: true)
    var records: [[String: Any]] = []
    var generatedCount = 0
    for index in characters.indices {
        guard let id = characters[index]["id"] as? String,
              characters[index]["assetDirectory"] as? String == id,
              let files = characters[index]["poseFiles"] as? [String], !files.isEmpty,
              Set(files).count == files.count, files.contains("idle.webp") else { fail("Invalid character entry") }
        let generated = Set(characters[index]["generatedPoses"] as? [String] ?? [])
        guard generated.isSubset(of: Set(files)) else { fail("Invalid generatedPoses") }
        let directory = artworkRoot.appendingPathComponent(id, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            guard file.range(of: "^[a-z0-9][a-z0-9_-]{0,47}\\.webp$", options: .regularExpression) != nil else {
                fail("Unsafe catalog filename")
            }
            let source = sourceRoot.appendingPathComponent(id).appendingPathComponent(file)
            guard source.resolvingSymlinksInPath().path == source.path else { fail("Symlink assets are not accepted") }
            let targetName = String(file.dropLast(5)) + ".png"
            let target = directory.appendingPathComponent(targetName)
            let image = try readImage(source)
            let sourcePixels = try rgba(image)
            let data = try png(image)
            // The whole output directory is a disposable build staging directory.
            try data.write(to: target)
            let decoded = try readImage(target)
            guard decoded.width == image.width, decoded.height == image.height,
                  try rgba(decoded) == sourcePixels else { fail("PNG changed decoded pixels: \(id)/\(file)") }
            records.append([
                "source": id + "/" + file, "output": id + "/" + targetName,
                "sourceSHA256": hash(try Data(contentsOf: source)), "outputSHA256": hash(data),
                "rgbaSHA256": hash(sourcePixels), "width": image.width, "height": image.height,
                "generated": generated.contains(file),
            ])
            if generated.contains(file) { generatedCount += 1 }
        }
        characters[index]["poseFiles"] = files.map { String($0.dropLast(5)) + ".png" }
        characters[index]["generatedPoses"] = (characters[index]["generatedPoses"] as? [String] ?? []).map { String($0.dropLast(5)) + ".png" }
    }
    document["characters"] = characters
    var handling = document["assetHandling"] as? [String: Any] ?? [:]
    handling["format"] = "Windows runtime copies are losslessly converted from catalog-listed WebP to PNG. Source filenames and both SHA-256 hashes are recorded in build-manifest.json; decoded premultiplied sRGB RGBA pixels were compared during conversion."
    handling["windowsConversion"] = ["sourceCatalog": "source-catalog.json", "manifest": "build-manifest.json", "license": "CC BY-NC-SA 4.0", "commercialUseAllowed": false]
    document["assetHandling"] = handling
    try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: artworkRoot.appendingPathComponent("catalog.json"))
    try catalogData.write(to: artworkRoot.appendingPathComponent("source-catalog.json"))
    for file in ["CHARACTERS-LICENSE.md", "ATTRIBUTION.md"] {
        try manager.copyItem(at: sourceRoot.appendingPathComponent(file), to: artworkRoot.appendingPathComponent(file))
    }
    let note = """
    # Windows runtime conversion

    These PNG files are converted copies of the WebP files explicitly listed in source-catalog.json.
    Pose names and character IDs are unchanged. build-manifest.json records source/output hashes,
    dimensions, source provenance and a decoded-pixel hash; every conversion was decoded again and
    compared in premultiplied sRGB RGBA. This format conversion is not new character artwork.
    The original ATTRIBUTION.md and full CC BY-NC-SA 4.0 license are included unchanged.
    Non-commercial use only; preserve attribution and share derivatives under the same license.
    """
    try Data(note.utf8).write(to: artworkRoot.appendingPathComponent("WINDOWS-ASSETS.md"))
    let iconData = try icon(try readImage(iconURL))
    let manifest: [String: Any] = ["schemaVersion": 1, "sourceCatalogSHA256": hash(catalogData), "iconSourceSHA256": hash(try Data(contentsOf: iconURL)), "iconSHA256": hash(iconData), "poseCount": records.count, "upstreamCount": records.count - generatedCount, "generatedCount": generatedCount, "assets": records]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artworkRoot.appendingPathComponent("build-manifest.json"))
    try iconData.write(to: outputRoot.appendingPathComponent("App.ico"))
    print("Windows assets: \(records.count) PNG; \(records.count - generatedCount) upstream + \(generatedCount) generated; all decoded pixels verified.")
} catch {
    try? manager.removeItem(at: outputRoot)
    fail("Windows asset preparation failed: \(error.localizedDescription)")
}
