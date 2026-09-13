// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RAPPShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RAPPShot", targets: ["RAPPShot"]),
        .library(name: "RAPPShotCore", targets: ["RAPPShotCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/kody-w/rapp-tools.git",
                 revision: "f0bc616c2aed34f2a88888806ed056ec7bafba61")
    ],
    targets: [
        .target(name: "RAPPShotCore"),
        .executableTarget(name: "RAPPShot", dependencies: [
            "RAPPShotCore",
            .product(name: "RAPPDesktopSupport", package: "rapp-tools")
        ]),
        .testTarget(name: "RAPPShotCoreTests", dependencies: ["RAPPShotCore"])
    ]
)
