// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HanaDesktopPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HanaDesktopPet", targets: ["HanaDesktopPet"]),
        .executable(name: "PetCoreChecks", targets: ["PetCoreChecks"]),
    ],
    targets: [
        .target(name: "PetCore", path: "Sources/PetCore"),
        .target(name: "PetBridge", dependencies: ["PetCore"], path: "Sources/PetBridge"),
        .executableTarget(
            name: "HanaDesktopPet",
            dependencies: ["PetCore", "PetBridge"],
            path: "Sources/HanaDesktopPet",
            exclude: ["Resources"]
        ),
        .executableTarget(
            name: "PetCoreChecks",
            dependencies: ["PetCore", "PetBridge"],
            path: "Tests/PetCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
