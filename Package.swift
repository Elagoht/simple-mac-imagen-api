// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "resimuretici",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", "4.100.0"..<"5.0.0"),
        .package(url: "https://github.com/apple/ml-stable-diffusion.git", "1.0.0"..<"3.0.0"),
        // CLT'de toolchain'in gömülü Testing macro plugin'i bulunamadığı için açık bağımlılık:
        // paket sürümü kendi TestingMacros plugin'ini derler ve yükler.
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "resimuretici",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "StableDiffusion", package: "ml-stable-diffusion"),
            ]
        ),
        .testTarget(
            name: "ResimUreticiTests",
            dependencies: [
                .byName(name: "resimuretici"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            // CLT, _TestingInterop'ı SwiftPM'in beklediği yoldan farklı yerde tutar
            // (Library/Developer/usr/lib); SwiftPM Developer/usr/lib yolunu arıyor.
            linkerSettings: [
                .unsafeFlags([
                    "-L/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ]
        ),
    ]
)
