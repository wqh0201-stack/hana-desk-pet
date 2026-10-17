import Foundation

/// One visible pose layer's contribution to a single pixel of the composited character.
public struct PetPoseAlphaSample: Equatable, Sendable {
    public let opacity: Double
    public let alpha: UInt8

    public init(opacity: Double, alpha: UInt8) {
        self.opacity = opacity
        self.alpha = alpha
    }
}

/// The single framework-free rule shared by drawing and alpha hit testing.
///
/// Layers stack exactly the way `NSImage.draw` composites them, so the surviving
/// coverage of a pixel is `1 - Π(1 - opacity_i × alpha_i)`. A nearly invisible
/// layer therefore cannot keep capturing clicks during a cross-fade, while a
/// settled fully opaque frame keeps the original single-frame alpha floor of
/// 16 of 255. Pixels outside a layer's image rect contribute alpha 0.
public enum PetPoseHitCoverage {
    /// Matches the previous single-frame `minimumAlpha` of 16 of 255.
    public static let minimumCoverage: Double = 16.0 / 255.0

    public static func coverage(_ samples: [PetPoseAlphaSample]) -> Double {
        var remaining = 1.0
        for sample in samples {
            let opacity = sample.opacity.isFinite ? min(1, max(0, sample.opacity)) : 0
            let alpha = Double(sample.alpha) / 255.0
            remaining *= 1 - opacity * alpha
        }
        return 1 - remaining
    }

    public static func isHit(_ samples: [PetPoseAlphaSample]) -> Bool {
        coverage(samples) >= minimumCoverage
    }
}
