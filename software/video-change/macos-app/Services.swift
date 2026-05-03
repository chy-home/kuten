import Foundation

enum AppRuntimeError: LocalizedError {
    case missingDependency(String)
    case detectorFailed(String)
    case invalidDetectorOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingDependency(let message):
            return message
        case .detectorFailed(let message):
            return message
        case .invalidDetectorOutput(let message):
            return message
        }
    }
}

struct RuntimeConfiguration {
    let pythonURL: URL
    let detectorScriptURL: URL
    let ffmpegURL: URL

    var subprocessEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let currentPath = environment["PATH"] ?? ""
        var pathEntries = [
            pythonURL.deletingLastPathComponent().path,
            ffmpegURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        if !currentPath.isEmpty {
            pathEntries.append(contentsOf: currentPath.split(separator: ":").map(String.init))
        }

        var deduplicated: [String] = []
        for entry in pathEntries where !entry.isEmpty {
            if !deduplicated.contains(entry) {
                deduplicated.append(entry)
            }
        }
        environment["PATH"] = deduplicated.joined(separator: ":")
        return environment
    }
}

enum RuntimeResolver {
    static func resolve() throws -> RuntimeConfiguration {
        let fileManager = FileManager.default
        let bundleURL = Bundle.main.bundleURL
        let resourceURL = Bundle.main.resourceURL
        let bundleParentURL = bundleURL.deletingLastPathComponent()
        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        let pythonCandidates = [
            resourceURL?.appendingPathComponent("venv/bin/python"),
            bundleParentURL.appendingPathComponent(".venv/bin/python"),
            currentDirectoryURL.appendingPathComponent(".venv/bin/python"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]

        let scriptCandidates = [
            resourceURL?.appendingPathComponent("detect_scene_changes.py"),
            bundleParentURL.appendingPathComponent("detect_scene_changes.py"),
            currentDirectoryURL.appendingPathComponent("detect_scene_changes.py"),
        ]

        let ffmpegCandidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/bin/ffmpeg"),
        ]

        guard let pythonURL = firstExecutable(in: pythonCandidates) else {
            throw AppRuntimeError.missingDependency("未找到可用的 Python 解释器。请先在项目根目录准备 .venv/bin/python。")
        }

        guard let detectorScriptURL = firstReadableFile(in: scriptCandidates) else {
            throw AppRuntimeError.missingDependency("未找到 detect_scene_changes.py。")
        }

        guard let ffmpegURL = firstExecutable(in: ffmpegCandidates) else {
            throw AppRuntimeError.missingDependency("未找到 ffmpeg。请确认 ffmpeg 已安装在 /opt/homebrew/bin 或 /usr/local/bin。")
        }

        return RuntimeConfiguration(
            pythonURL: pythonURL,
            detectorScriptURL: detectorScriptURL,
            ffmpegURL: ffmpegURL
        )
    }

    private static func firstExecutable(in candidates: [URL?]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates.compactMap({ $0 }) {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func firstReadableFile(in candidates: [URL?]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates.compactMap({ $0 }) {
            if fileManager.isReadableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

final class DetectorService {
    private let runtime: RuntimeConfiguration

    init(runtime: RuntimeConfiguration) {
        self.runtime = runtime
    }

    func detect(
        videoURL: URL,
        skipStartSeconds: Double,
        fadeRemovalStrategy: FadeRemovalStrategy,
        fadeLeftPaddingSeconds: Double,
        fadeRightPaddingSeconds: Double,
        completion: @escaping (Result<DetectorPayload, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try self.detectSync(
                    videoURL: videoURL,
                    skipStartSeconds: skipStartSeconds,
                    fadeRemovalStrategy: fadeRemovalStrategy,
                    fadeLeftPaddingSeconds: fadeLeftPaddingSeconds,
                    fadeRightPaddingSeconds: fadeRightPaddingSeconds
                )
                completion(.success(payload))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func detectSync(
        videoURL: URL,
        skipStartSeconds: Double = 0.0,
        fadeRemovalStrategy: FadeRemovalStrategy = .defaultValue,
        fadeLeftPaddingSeconds: Double,
        fadeRightPaddingSeconds: Double
    ) throws -> DetectorPayload {
        let process = Process()
        process.executableURL = runtime.pythonURL
        process.arguments = [
            runtime.detectorScriptURL.path,
            videoURL.path,
            "--skip-start-seconds",
            String(max(0.0, skipStartSeconds)),
            "--fade-removal-profile",
            fadeRemovalStrategy.pythonArgument,
            "--fade-left-padding-seconds",
            String(max(0.0, fadeLeftPaddingSeconds)),
            "--fade-right-padding-seconds",
            String(max(0.0, fadeRightPaddingSeconds)),
            "--json",
        ]
        process.currentDirectoryURL = runtime.detectorScriptURL.deletingLastPathComponent()
        process.environment = runtime.subprocessEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppRuntimeError.detectorFailed("解析失败：\(message)")
        }

        guard let jsonData = stdoutText.data(using: .utf8) else {
            throw AppRuntimeError.invalidDetectorOutput("检测脚本没有返回有效的 JSON。")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        do {
            return try decoder.decode(DetectorPayload.self, from: jsonData)
        } catch {
            throw AppRuntimeError.invalidDetectorOutput("无法解析检测脚本输出：\(error.localizedDescription)")
        }
    }
}
