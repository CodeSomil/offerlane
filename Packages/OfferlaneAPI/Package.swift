// swift-tools-version:5.10
// Typed Swift client for the Offerlane cloud API (P2.8), generated at build time from libs/contract/openapi.json.
import PackageDescription

let package = Package(
    name: "OfferlaneAPI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "OfferlaneAPI", targets: ["OfferlaneAPI"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.3"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.3"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"), // already a runtime dependency; named for the middleware
        .package(path: "../OfferlaneCore"), // tests only: the live sync check (SyncLiveTests)
    ],
    targets: [
        .target(name: "OfferlaneAPI", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ], plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]),
        .testTarget(name: "OfferlaneAPITests", dependencies: [
            "OfferlaneAPI",
            .product(name: "OfferlaneCore", package: "OfferlaneCore"),
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ]),
    ]
)
