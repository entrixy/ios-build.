// swift-tools-version: 5.9
import PackageDescription

#if os(Linux)
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")
]
let coreDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto")]
#else
let dependencies: [Package.Dependency] = []
let coreDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "Entrixy",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "EntrixyCore", targets: ["EntrixyCore"])],
    dependencies: dependencies,
    targets: [
        .target(name: "EntrixyCore", dependencies: coreDependencies),
        .testTarget(name: "EntrixyCoreTests", dependencies: ["EntrixyCore"],
                    resources: [.copy("Fixtures")])
    ]
)
