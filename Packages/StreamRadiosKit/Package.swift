// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamRadiosKit",
    platforms: [.iOS("26.0")],
    products: [
        .library(name: "StreamRadiosKit", targets: ["StreamRadiosKit"])
    ],
    targets: [
        .target(
            name: "StreamRadiosKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
