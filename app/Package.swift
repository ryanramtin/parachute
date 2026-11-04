// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Parachute",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Parachute", targets: ["Parachute"]),
        .executable(name: "parachute-render-sheet", targets: ["parachute-render-sheet"]),
    ],
    targets: [
        .target(name: "ParachuteCore"),
        .executableTarget(name: "Parachute", dependencies: ["ParachuteCore"]),
        .executableTarget(name: "parachute-render-sheet", dependencies: ["ParachuteCore"]),
        .testTarget(name: "ParachuteCoreTests", dependencies: ["ParachuteCore"]),
    ]
)
