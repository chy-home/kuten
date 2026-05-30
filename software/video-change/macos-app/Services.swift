import Foundation

enum AppRuntimeError: LocalizedError {
    case missingDependency(String)
    case detectorFailed(String)
    case invalidDetectorOutput(String)
    case operationCancelled(String)
    case mediaProbeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingDependency(let message):
            return message
        case .detectorFailed(let message):
            return message
        case .invalidDetectorOutput(let message):
            return message
        case .operationCancelled(let message):
            return message
        case .mediaProbeFailed(let message):
            return message
        }
    }
}

struct RuntimeConfiguration {
    let pythonURL: URL
    let detectorScriptURL: URL
    let ffmpegURL: URL
    let ffprobeURL: URL?

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

        guard let pythonURL = firstUsablePython(in: pythonCandidates) else {
            throw AppRuntimeError.missingDependency("未找到可用的 Python 解释器。请先在项目根目录准备 .venv/bin/python，并确认已安装 numpy、scenedetect 与 opencv-python。")
        }

        guard let detectorScriptURL = firstReadableFile(in: scriptCandidates) else {
            throw AppRuntimeError.missingDependency("未找到 detect_scene_changes.py。")
        }

        guard let ffmpegURL = firstExecutable(in: ffmpegCandidates) else {
            throw AppRuntimeError.missingDependency("未找到 ffmpeg。请确认 ffmpeg 已安装在 /opt/homebrew/bin 或 /usr/local/bin。")
        }

        let ffprobeCandidates: [URL?] = [
            ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/local/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/bin/ffprobe"),
        ]
        let ffprobeURL = firstExecutable(in: ffprobeCandidates)

        return RuntimeConfiguration(
            pythonURL: pythonURL,
            detectorScriptURL: detectorScriptURL,
            ffmpegURL: ffmpegURL,
            ffprobeURL: ffprobeURL
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

    private static func firstUsablePython(in candidates: [URL?]) -> URL? {
        let fileManager = FileManager.default
        for candidate in candidates.compactMap({ $0 }) {
            guard fileManager.isExecutableFile(atPath: candidate.path) else {
                continue
            }
            guard pythonHasRequiredModules(candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func pythonHasRequiredModules(_ pythonURL: URL) -> Bool {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [
            "-c",
            "import numpy, scenedetect, cv2",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
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

    @discardableResult
    func detect(
        videoURL: URL,
        skipStartSeconds: Double,
        fadeRemovalStrategy: FadeRemovalStrategy,
        fadeLeftPaddingSeconds: Double,
        fadeRightPaddingSeconds: Double,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<DetectorPayload, Error>) -> Void
    ) -> DetectorCancellation {
        let cancellation = DetectorCancellation()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let payload = try self.detectSync(
                    videoURL: videoURL,
                    skipStartSeconds: skipStartSeconds,
                    fadeRemovalStrategy: fadeRemovalStrategy,
                    fadeLeftPaddingSeconds: fadeLeftPaddingSeconds,
                    fadeRightPaddingSeconds: fadeRightPaddingSeconds,
                    progress: progress,
                    cancellation: cancellation
                )
                if cancellation.isCancelled {
                    completion(.failure(AppRuntimeError.operationCancelled("解析已停止。")))
                    return
                }
                completion(.success(payload))
            } catch {
                completion(.failure(error))
            }
        }
        return cancellation
    }

    func detectSync(
        videoURL: URL,
        skipStartSeconds: Double = 0.0,
        fadeRemovalStrategy: FadeRemovalStrategy = .defaultValue,
        fadeLeftPaddingSeconds: Double,
        fadeRightPaddingSeconds: Double,
        progress: ((String) -> Void)? = nil,
        cancellation: DetectorCancellation? = nil
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

        let bufferQueue = DispatchQueue(label: "DetectorService.pipe-buffer")
        var stdoutBuffer = Data()
        var stderrBuffer = Data()
        var stderrProgressBuffer = Data()

        if cancellation?.isCancelled == true {
            throw AppRuntimeError.operationCancelled("解析已停止。")
        }
        cancellation?.attach(process: process)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            bufferQueue.sync {
                stdoutBuffer.append(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }

            var lines: [String] = []
            bufferQueue.sync {
                stderrBuffer.append(data)
                stderrProgressBuffer.append(data)
                while let newlineRange = stderrProgressBuffer.range(of: Data([0x0a])) {
                    let lineData = stderrProgressBuffer.subdata(in: 0..<newlineRange.lowerBound)
                    stderrProgressBuffer.removeSubrange(0...newlineRange.lowerBound)
                    let line = String(data: lineData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !line.isEmpty {
                        lines.append(line)
                    }
                }
            }

            for line in lines {
                progress?(line)
            }
        }

        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            cancellation?.detachProcess()
        }

        try process.run()
        process.waitUntilExit()

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        var finalStdoutData = Data()
        var finalStderrData = Data()
        var trailingLines: [String] = []

        bufferQueue.sync {
            if !remainingStdout.isEmpty {
                stdoutBuffer.append(remainingStdout)
            }
            if !remainingStderr.isEmpty {
                stderrBuffer.append(remainingStderr)
                stderrProgressBuffer.append(remainingStderr)
            }
            let trailingLine = String(data: stderrProgressBuffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trailingLine.isEmpty {
                trailingLines.append(trailingLine)
            }
            finalStdoutData = stdoutBuffer
            finalStderrData = stderrBuffer
        }

        for line in trailingLines {
            progress?(line)
        }

        let stdoutData = finalStdoutData
        let stderrData = finalStderrData
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

        if cancellation?.isCancelled == true {
            throw AppRuntimeError.operationCancelled("解析已停止。")
        }
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

final class DetectorCancellation {
    private let stateQueue = DispatchQueue(label: "DetectorService.cancellation-state")
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        stateQueue.sync { cancelled }
    }

    func attach(process: Process) {
        let shouldCancel = stateQueue.sync { () -> Bool in
            self.process = process
            return cancelled
        }
        if shouldCancel {
            terminate(process)
        }
    }

    func detachProcess() {
        stateQueue.sync {
            process = nil
        }
    }

    func cancel() {
        let processToCancel = stateQueue.sync { () -> Process? in
            cancelled = true
            return process
        }
        guard let processToCancel else {
            return
        }
        terminate(processToCancel)
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }
        process.terminate()
    }
}

final class MediaProbeService {
    private let runtime: RuntimeConfiguration

    init(runtime: RuntimeConfiguration) {
        self.runtime = runtime
    }

    func resolveDuration(videoURL: URL) throws -> Double {
        if let ffprobeURL = runtime.ffprobeURL, let duration = try probeDurationWithFFprobe(videoURL: videoURL, ffprobeURL: ffprobeURL) {
            return duration
        }
        if let duration = try probeDurationWithFFmpeg(videoURL: videoURL) {
            return duration
        }
        throw AppRuntimeError.mediaProbeFailed("无法获取视频时长。")
    }

    private func probeDurationWithFFprobe(videoURL: URL, ffprobeURL: URL) throws -> Double? {
        let result = try runProcess(
            executableURL: ffprobeURL,
            arguments: [
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                videoURL.path,
            ]
        )

        guard result.terminationStatus == 0 else {
            return nil
        }

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Double(trimmed), duration.isFinite, duration > 0 else {
            return nil
        }
        return duration
    }

    private func probeDurationWithFFmpeg(videoURL: URL) throws -> Double? {
        let result = try runProcess(
            executableURL: runtime.ffmpegURL,
            arguments: [
                "-hide_banner",
                "-i",
                videoURL.path,
            ]
        )

        let combinedOutput = [result.stdout, result.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combinedOutput.isEmpty else {
            return nil
        }
        return parseDurationFromFFmpegOutput(combinedOutput)
    }

    private func runProcess(executableURL: URL, arguments: [String]) throws -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = runtime.subprocessEnvironment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func parseDurationFromFFmpegOutput(_ output: String) -> Double? {
        let pattern = #"Duration:\s*(\d{2}):(\d{2}):(\d{2}(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
        guard
            let match = regex.firstMatch(in: output, options: [], range: nsRange),
            match.numberOfRanges == 4,
            let hoursRange = Range(match.range(at: 1), in: output),
            let minutesRange = Range(match.range(at: 2), in: output),
            let secondsRange = Range(match.range(at: 3), in: output),
            let hours = Double(output[hoursRange]),
            let minutes = Double(output[minutesRange]),
            let seconds = Double(output[secondsRange])
        else {
            return nil
        }

        let duration = hours * 3600.0 + minutes * 60.0 + seconds
        return duration > 0 ? duration : nil
    }
}
