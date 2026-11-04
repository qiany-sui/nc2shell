// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Nc2Shell",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Nc2ShellCore", targets: ["Nc2ShellCore"]),
        .executable(name: "Nc2Shell", targets: ["Nc2Shell"])
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.18.0")],
    targets: [
        .target(name: "Nc2ShellCore"),
        .target(name: "Nc2ShellAuthSupport"),
        .executableTarget(name: "Nc2Shell", dependencies: ["Nc2ShellCore", "Nc2ShellAuthSupport", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "Nc2ShellCoreTests", dependencies: ["Nc2ShellCore"]),
        .testTarget(name: "Nc2ShellTests", dependencies: ["Nc2Shell"])
    ]
)
