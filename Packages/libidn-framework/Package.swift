// swift-tools-version:5.1
import PackageDescription

// Подменяет одноимённую зависимость XMPPFramework (chrisballinger/libidn-framework, LGPL):
// те же модуль и методы idn_prep*, но на Foundation и без кода GNU libidn.
let package = Package(
    name: "libidn",
    platforms: [
        .iOS(.v12),
        .macOS(.v10_13)
    ],
    products: [
        .library(name: "libidn", targets: ["libidn"])
    ],
    targets: [
        .target(name: "libidn", path: "Sources/libidn", publicHeadersPath: "include"),
        .testTarget(name: "libidnTests", dependencies: ["libidn"], path: "Tests/libidnTests")
    ]
)
