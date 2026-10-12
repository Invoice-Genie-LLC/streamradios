// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamRadiosKit",
    platforms: [
        .iOS("26.0"),
        .watchOS("26.0")
    ],
    products: [
        .library(name: "StreamRadiosKit", targets: ["StreamRadiosKit"]),
        .library(name: "StreamRadiosCore", targets: ["StreamRadiosCore"])
    ],
    targets: [
        .target(
            name: "StreamRadiosKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "StreamRadiosCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StreamRadiosCoreTests",
            dependencies: ["StreamRadiosCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
