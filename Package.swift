// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tidsmaskinen",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Tidsmaskinen", targets: ["Tidsmaskinen"]),
        .executable(name: "tm-hook", targets: ["tm-hook"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0")
    ],
    targets: [
        .executableTarget(
            name: "Tidsmaskinen",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Tidsmaskinen"
        ),
        .executableTarget(
            name: "tm-hook",
            path: "Sources/tm-hook"
        )
    ]
)
