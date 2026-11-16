// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CloudHarbor", platforms: [.macOS(.v14)], products: [.executable(name: "CloudHarbor", targets: ["CloudHarbor"])], targets: [
    .target(name: "HarborCore"),
    .target(name: "HarborEngine", dependencies: ["HarborCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "CloudHarbor", dependencies: ["HarborCore", "HarborEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "SafetyChecks", dependencies: ["HarborCore"], path: "Tests/HarborCoreTests"),
    .executableTarget(name: "EngineChecks", dependencies: ["HarborCore", "HarborEngine"], path: "Tests/EngineChecks", resources: [.copy("FakeMega.py")], swiftSettings: [.swiftLanguageMode(.v5)])
])
