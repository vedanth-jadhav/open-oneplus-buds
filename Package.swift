// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Buds",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "BudsCore", targets: ["BudsCore"]),
        .executable(name: "BudsApp", targets: ["BudsApp"]),
        .executable(name: "BudsSelfTest", targets: ["BudsSelfTest"]),
        .executable(name: "BudsSniffer", targets: ["BudsSniffer"])
    ],
    targets: [
        .target(
            name: "BudsCore",
            dependencies: []
        ),
        .executableTarget(
            name: "BudsApp",
            dependencies: ["BudsCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "BudsSelfTest",
            dependencies: ["BudsCore"]
        ),
        .executableTarget(
            name: "BudsSniffer",
            dependencies: ["BudsCore"]
        )
    ]
)
