// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotoSearch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Shared sorting/metadata/geocoding code. Local checkout during
        // development; CI points this at the GitHub repo instead.
        .package(path: "../photo-sorter"),
        // Hugging Face tokenizers (tokenizer.json), for models like SigLIP 2.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.4"),
    ],
    targets: [
        .executableTarget(
            name: "PhotoSearch",
            dependencies: [
                .product(name: "PhotoSorterCore", package: "photo-sorter"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/PhotoSearch"
        ),
    ]
)
