// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Loaderoo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Loaderoo", targets: ["LoaderooApp"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0")],
    targets: [
        .target(name: "LoaderooCore",
                dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                resources: [.process("Resources")]),
        .executableTarget(name: "LoaderooApp", dependencies: ["LoaderooCore"]),
        .testTarget(name: "LoaderooCoreTests", dependencies: ["LoaderooCore"]),
    ]
)
