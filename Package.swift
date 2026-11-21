// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "iTunes", platforms: [.macOS(.v13)], targets: [
    .target(name: "MTPSupport", path: "Native", exclude: ["TagWriter.mm", "TagLibHeaders"], publicHeadersPath: "include"),
    .executableTarget(name: "iTunes", dependencies: ["MTPSupport"])
])
