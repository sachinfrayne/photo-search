import Foundation

/// Where PhotoSearch keeps its bundled tools and its own data.
enum AppPaths {
    /// Inside the .app: Qdrant sits next to our executable in Contents/MacOS
    /// and the models in Contents/Resources/models. Run from source
    /// (`swift run`), both come from the repo's vendor/ folder, populated by
    /// scripts/fetch_deps.sh.
    private static let isBundled = Bundle.main.url(forAuxiliaryExecutable: "qdrant") != nil

    private static let vendor: URL = {
        if let env = ProcessInfo.processInfo.environment["PHOTOSEARCH_VENDOR"] {
            return URL(fileURLWithPath: env)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("vendor")
    }()

    static var qdrantBinary: URL {
        isBundled ? Bundle.main.url(forAuxiliaryExecutable: "qdrant")! : vendor.appendingPathComponent("qdrant")
    }

    static var models: URL {
        isBundled ? Bundle.main.resourceURL!.appendingPathComponent("models") : vendor.appendingPathComponent("models")
    }

    /// Persistent data: the vector index and compiled models.
    static let support: URL = {
        let base = ProcessInfo.processInfo.environment["PHOTOSEARCH_DATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PhotoSearch")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Throwaway data that can be regenerated: thumbnails.
    static let thumbnails: URL = {
        let dir = support.appendingPathComponent("Thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
