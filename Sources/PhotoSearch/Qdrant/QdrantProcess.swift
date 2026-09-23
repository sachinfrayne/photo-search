import Darwin
import Foundation

/// Runs the bundled Qdrant binary as a hidden child process, bound to
/// localhost on a free port with a per-launch API key, storing its data in
/// Application Support. The user never sees it.
final class QdrantProcess: @unchecked Sendable {
    enum Failure: LocalizedError {
        case binaryMissing(String)
        case notReady(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing(let path): return "The search engine is missing from the app (\(path))."
            case .notReady(let log): return "The search engine didn't start.\n\(log)"
            }
        }
    }

    private(set) var baseURL = URL(string: "http://127.0.0.1:6333")!
    let apiKey = UUID().uuidString
    private var process: Process?
    private let logPipe = Pipe()
    private var recentLog = ""
    private let lock = NSLock()
    private var stopping = false
    private var restarted = false

    private let storage = AppPaths.support.appendingPathComponent("qdrant-storage")
    private let pidFile = AppPaths.support.appendingPathComponent("qdrant.pid")

    func start() async throws {
        let binary = AppPaths.qdrantBinary
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.binaryMissing(binary.path)
        }
        killStaleProcess()
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)

        let httpPort = Self.freePort()
        let grpcPort = Self.freePort()
        baseURL = URL(string: "http://127.0.0.1:\(httpPort)")!

        // A tiny shell watchdog owns Qdrant so it can never outlive the app,
        // even if the app crashes or is force-quit (macOS has no
        // "die with parent" option for child processes).
        let watchdog = """
        "$QDRANT_BIN" & child=$!
        echo $child > "$QDRANT_PIDFILE"
        trap 'kill -TERM $child 2>/dev/null; wait $child; exit 0' TERM INT
        while kill -0 $APP_PID 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 1; done
        kill -TERM $child 2>/dev/null; wait $child
        """

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog]
        p.currentDirectoryURL = AppPaths.support
        p.environment = [
            "QDRANT_BIN": binary.path,
            "QDRANT_PIDFILE": pidFile.path,
            "APP_PID": String(getpid()),
            "QDRANT__STORAGE__STORAGE_PATH": storage.path,
            "QDRANT__STORAGE__SNAPSHOTS_PATH": AppPaths.support.appendingPathComponent("qdrant-snapshots").path,
            "QDRANT__SERVICE__HOST": "127.0.0.1",
            "QDRANT__SERVICE__HTTP_PORT": String(httpPort),
            "QDRANT__SERVICE__GRPC_PORT": String(grpcPort),
            "QDRANT__SERVICE__API_KEY": apiKey,
            "QDRANT__TELEMETRY_DISABLED": "true",
            "QDRANT__LOG_LEVEL": "WARN",
        ]
        p.standardOutput = logPipe
        p.standardError = logPipe
        logPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let s = String(data: handle.availableData, encoding: .utf8), !s.isEmpty else { return }
            self.lock.withLock { self.recentLog = String((self.recentLog + s).suffix(4000)) }
        }
        p.terminationHandler = { [weak self] proc in self?.handleExit(proc) }

        try p.run()
        process = p
        try await waitUntilReady()
    }

    func stop() {
        lock.withLock { stopping = true }
        guard let p = process, p.isRunning else { return }
        p.terminate()  // the watchdog passes this on to Qdrant and waits for it
        // Give Qdrant a moment to flush its write-ahead log, then make sure it's gone.
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            killStaleProcess()
            kill(p.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func waitUntilReady() async throws {
        let url = baseURL.appendingPathComponent("readyz")
        var request = URLRequest(url: url, timeoutInterval: 1)
        request.setValue(apiKey, forHTTPHeaderField: "api-key")
        for _ in 0..<150 {
            if let (_, resp) = try? await URLSession.shared.data(for: request),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            if process?.isRunning == false { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure.notReady(lock.withLock { recentLog })
    }

    /// If Qdrant dies unexpectedly (not because we asked it to), restart it once.
    private func handleExit(_ proc: Process) {
        let shouldRestart = lock.withLock { () -> Bool in
            guard !stopping, !restarted else { return false }
            restarted = true
            return true
        }
        guard shouldRestart else { return }
        Task { try? await self.start() }
    }

    /// After a crash or force-quit the old Qdrant may still hold the storage
    /// lock. Only kill it if the PID really belongs to a qdrant process.
    private func killStaleProcess() {
        guard let s = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name) == "qdrant" {
            kill(pid, SIGTERM)
            for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
