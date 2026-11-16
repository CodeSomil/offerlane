// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OfferlaneCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OfferlaneCore", targets: ["OfferlaneCore"]),
               .executable(name: "offerlane-modelcheck", targets: ["offerlane-modelcheck"]),
               .executable(name: "offerlane-mcp", targets: ["offerlane-mcp"])],
    dependencies: [
        .package(path: "../GRDB-SQLCipher"),  // GRDB 7.11.1 + SQLCipher (P1.7)
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "OfferlaneCore", dependencies: [
            .product(name: "GRDB", package: "GRDB-SQLCipher"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], resources: [.copy("Resources")]),
        .executableTarget(name: "offerlane-modelcheck", dependencies: ["OfferlaneCore"]),
        .executableTarget(name: "offerlane-mcp", dependencies: ["OfferlaneCore"]),
        .testTarget(name: "OfferlaneCoreTests", dependencies: ["OfferlaneCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
                    resources: [.copy("Fixtures")]),
    ]
)
