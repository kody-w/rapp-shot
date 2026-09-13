// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RAPPShot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RAPPShot", targets: ["RAPPShot"]),
        .library(name: "RAPPShotCore", targets: ["RAPPShotCore"])
    ],
    dependencies: [.package(path: "../../rapp-tools")],
    targets: [
        .target(name: "RAPPShotCore"),
        .executableTarget(name: "RAPPShot", dependencies: [
            "RAPPShotCore",
            .product(name: "RAPPDesktopSupport", package: "rapp-tools")
        ]),
        .testTarget(name: "RAPPShotCoreTests", dependencies: ["RAPPShotCore"])
    ]
)
