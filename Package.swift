// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Stenographer",
    platforms: [.macOS(.v26)],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7")],
    targets: [.executableTarget(name: "Stenographer",
                                dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                                swiftSettings: [.swiftLanguageMode(.v5)])]
)
