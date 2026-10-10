// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdrDesk",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
        .executable(name: "HerdrDesk", targets: ["HerdrDesk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0"),
    ],
    targets: [
        .target(name: "HerdrKit", exclude: ["README.md"]),
        .executableTarget(
            name: "HerdrDesk",
            dependencies: [
                "HerdrKit",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(name: "HerdrKitChecks", dependencies: ["HerdrKit"]),
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks", "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])]
        ),
    ]
)
