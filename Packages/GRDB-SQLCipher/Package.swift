// swift-tools-version:6.1
// Vendored fork of GRDB 7.11.1 (MIT, see LICENSE) with its documented "GRDB+SQLCipher" edits applied
// (Offerlane v4 P1.7). Only the library sources are kept; tests and docs live upstream.
// To update: copy GRDB/, Sources/GRDBSQLCipher and LICENSE from the new GRDB tag and re-apply these edits.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    .define("SQLITE_HAS_CODEC"),
    .define("SQLCipher"),
]

let package = Package(
    name: "GRDB",
    platforms: [.iOS(.v13), .macOS(.v10_15), .tvOS(.v13), .watchOS(.v7)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", from: "4.11.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: [.define("SQLITE_HAS_CODEC")],
            swiftSettings: swiftSettings + [.enableUpcomingFeature("MemberImportVisibility")]),
    ],
    swiftLanguageModes: [.v6]
)
