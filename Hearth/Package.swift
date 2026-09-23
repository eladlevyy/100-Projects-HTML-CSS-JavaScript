// swift-tools-version: 6.0
import PackageDescription

// Append Apple targets inside the function. A file-scope array concatenation
// across `#if os(macOS)` crashes the Linux manifest compiler.
func makePackage() -> Package {
    var products: [Product] = [
        .library(name: "HearthCore", targets: ["HearthCore"]),
    ]
    var targets: [Target] = [
        .target(
            name: "HearthCore",
            path: "Sources/HearthCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HearthCoreTests",
            dependencies: ["HearthCore"],
            path: "Tests/HearthCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]

    #if os(macOS)
    products.append(.library(name: "HearthMac", targets: ["HearthMac"]))
    products.append(.executable(name: "Hearth", targets: ["Hearth"]))
    targets.append(
        .target(
            name: "HearthMac",
            dependencies: ["HearthCore"],
            path: "Sources/HearthMac",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
    targets.append(
        .executableTarget(
            name: "Hearth",
            dependencies: ["HearthMac"],
            path: "Sources/Hearth",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
    targets.append(
        .testTarget(
            name: "HearthMacTests",
            dependencies: ["HearthMac"],
            path: "Tests/HearthMacTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
    return Package(
        name: "Hearth",
        platforms: [.macOS(.v14)],
        products: products,
        targets: targets
    )
    #else
    return Package(
        name: "Hearth",
        products: products,
        targets: targets
    )
    #endif
}

let package = makePackage()
