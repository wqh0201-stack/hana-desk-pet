import Foundation

/// One RGB colour, so the border colour stays pure data and testable without AppKit.
public struct PetBubbleAccent: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, for checks and for the Windows side to match byte for byte.
    public var hex: String {
        func channel(_ value: Double) -> String {
            let clamped = min(1, max(0, value))
            let byte = Int((clamped * 255).rounded())
            return String(format: "%02x", byte)
        }
        return "#" + channel(red) + channel(green) + channel(blue)
    }
}

/// The bubble's accent colour per character.
///
/// Source: upstream CrossPet v1.3.6 `characters/<role>/character.json` `accent`, used only
/// as a colour reference for the local prototype's border. No artwork, wording or other
/// asset is copied, so this is not an asset republication. Both native ends keep the same
/// small table; `assets/crosspet/catalog.json` is a material index and is deliberately not
/// touched.
public enum PetBubbleTheme {
    /// Characters without their own upstream accent (the two outfit skins) use this.
    public static let fallback = PetBubbleAccent(red: 0xE0 / 255, green: 0xB4 / 255, blue: 0x8A / 255)

    private static let accents: [String: PetBubbleAccent] = [
        "claude": PetBubbleAccent(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x3D / 255),
        "gpt": PetBubbleAccent(red: 0x7A / 255, green: 0x8F / 255, blue: 0xA8 / 255),
        "deepseek": PetBubbleAccent(red: 0x3B / 255, green: 0x5B / 255, blue: 0xB5 / 255),
        "gemini": PetBubbleAccent(red: 0x7B / 255, green: 0x5C / 255, blue: 0xD6 / 255),
        "glm": PetBubbleAccent(red: 0x4B / 255, green: 0x5A / 255, blue: 0x8A / 255),
        "deepseek-hoodie": fallback,
        "gpt-onesie": fallback,
    ]

    public static func accent(forRoleId roleId: String) -> PetBubbleAccent {
        accents[roleId] ?? fallback
    }

    public static var knownRoleIds: [String] { PetRole.builtIns.map(\.id) }
}
