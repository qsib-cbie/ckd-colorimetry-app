// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CKDKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CKDImage", targets: ["CKDImage"]),
        .library(name: "CKDResults", targets: ["CKDResults"]),
        .library(name: "CKDDocument", targets: ["CKDDocument"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19"),
    ],
    targets: [
        .binaryTarget(name: "LibRaw", path: "Frameworks/LibRaw.xcframework"),
        .target(
            name: "CKDRaw",
            dependencies: ["LibRaw"],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("c++")]
        ),
        .target(name: "CKDImage", dependencies: ["CKDRaw"]),
        .target(name: "CKDResults"),
        .target(
            name: "CKDDocument",
            dependencies: ["CKDImage", "CKDResults", .product(name: "ZIPFoundation", package: "ZIPFoundation")]
        ),
        .executableTarget(name: "ckd-contract", dependencies: ["CKDDocument"], path: "Sources/CKDContract"),
        .testTarget(name: "CKDImageTests", dependencies: ["CKDImage"]),
        .testTarget(name: "CKDResultsTests", dependencies: ["CKDResults"]),
        .testTarget(name: "CKDDocumentTests", dependencies: ["CKDDocument"]),
    ],
    swiftLanguageModes: [.v5]
)
