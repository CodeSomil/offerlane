// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "OfferlaneCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OfferlaneCore", targets: ["OfferlaneCore"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(name: "OfferlaneCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        ], resources: [.copy("Resources")]),
        .testTarget(name: "OfferlaneCoreTests", dependencies: ["OfferlaneCore", .product(name: "ZIPFoundation", package: "ZIPFoundation")],
                    resources: [.copy("Fixtures")]),
    ]
)
