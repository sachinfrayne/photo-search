// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoSearch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Shared sorting/metadata/geocoding code. Local checkout during
        // development; CI points this at the GitHub repo instead.
        .package(path: "../photo-sorter"),
    ],
    targets: [
        .executableTarget(
            name: "PhotoSearch",
            dependencies: [
                .product(name: "PhotoSorterCore", package: "photo-sorter"),
            ],
            path: "Sources/PhotoSearch"
        ),
    ]
)
