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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Tidsmaskinen",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Tidsmaskinen",
            linkerSettings: [
                // SPM only sets @executable_path on the rpath; Sparkle.framework
                // lives at Contents/Frameworks/ once make-app.sh bundles it, so
                // dyld needs this second rpath to find it at launch.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "tm-hook",
            path: "Sources/tm-hook"
        )
    ]
)
