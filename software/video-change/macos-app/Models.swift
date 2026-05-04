import Foundation

struct DetectorPayload: Decodable {
    let video: String
    let fps: Double
    let duration: Double
    let aggressive: Bool
    let fadeRemovalProfile: String?
    let events: [TransitionEvent]
    let keepSegments: [KeepSegment]
}

struct FadePaddingSettings {
    let leftSeconds: Double
    let rightSeconds: Double
}

enum FadeRemovalStrategy: String, CaseIterable {
    case conservative
    case standard
    case aggressive
    case extreme

    var displayName: String {
        switch self {
        case .conservative:
            return "保守"
        case .standard:
            return "标准"
        case .aggressive:
            return "激进"
        case .extreme:
            return "极激进"
        }
    }

    var pythonArgument: String {
        rawValue
    }

    var defaultPaddingSettings: FadePaddingSettings {
        switch self {
        case .conservative:
            return FadePaddingSettings(leftSeconds: 0.04, rightSeconds: 0.12)
        case .standard:
            return FadePaddingSettings(leftSeconds: 0.08, rightSeconds: 0.18)
        case .aggressive:
            return FadePaddingSettings(leftSeconds: 0.12, rightSeconds: 0.24)
        case .extreme:
            return FadePaddingSettings(leftSeconds: 0.16, rightSeconds: 0.32)
        }
    }

    static let defaultValue: FadeRemovalStrategy = .aggressive

    init(pythonArgument: String?) {
        guard let pythonArgument, let value = FadeRemovalStrategy(rawValue: pythonArgument) else {
            self = .defaultValue
            return
        }
        self = value
    }
}

struct TransitionEvent: Decodable {
    let index: Int
    let type: String
    let start: Double
    let end: Double
    let duration: Double
    let score: Double
    let source: String
}

struct KeepSegment: Decodable {
    let index: Int
    let start: Double
    let end: Double
    let duration: Double
}

struct EditableSegment {
    let index: Int
    var isEnabled: Bool
    var start: Double
    var end: Double

    var duration: Double {
        max(0.0, end - start)
    }
}

struct CropParameters {
    let width: Int
    let height: Int
    let x: Int
    let y: Int

    var filterExpression: String {
        "crop=\(width):\(height):\(x):\(y)"
    }
}

struct FFmpegJob {
    let index: Int
    let inputURL: URL
    let outputURL: URL
    let start: Double
    let duration: Double
    let crop: CropParameters?

    var arguments: [String] {
        baseArguments(includeExecutionFlags: false)
    }

    var executionArguments: [String] {
        baseArguments(includeExecutionFlags: true)
    }

    private var videoFilterExpression: String? {
        crop?.filterExpression
    }

    private func baseArguments(includeExecutionFlags: Bool) -> [String] {
        var args = [
            "-y",
            "-hide_banner",
        ]

        if includeExecutionFlags {
            args += [
                "-nostdin",
                "-stats_period",
                "0.5",
                "-progress",
                "pipe:2",
            ]
        }

        args += [
            "-ss",
            formatSecondsArgument(start),
            "-i",
            inputURL.path,
            "-t",
            formatSecondsArgument(duration),
        ]

        args += [
            "-strict",
            "-2",
        ]

        if let videoFilterExpression {
            args += ["-vf", videoFilterExpression]
        }

        args.append(outputURL.path)

        return args
    }

    var commandPreview: String {
        let components = ["ffmpeg"] + arguments
        return components.map(shellQuoted).joined(separator: " ")
    }
}

func formatHMS(_ seconds: Double) -> String {
    let bounded = max(0.0, seconds)
    let whole = Int(bounded)
    var millis = Int(((bounded - Double(whole)) * 1000.0).rounded())
    var wholeSeconds = whole
    if millis == 1000 {
        wholeSeconds += 1
        millis = 0
    }

    let hours = wholeSeconds / 3600
    let minutes = (wholeSeconds % 3600) / 60
    let secs = wholeSeconds % 60
    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
}

func formatSecondsArgument(_ seconds: Double) -> String {
    let bounded = max(0.0, seconds)
    let formatted = String(format: "%.3f", bounded)
    let trimmed = formatted.replacingOccurrences(of: #"(\.\d*?[1-9])0+$"#, with: "$1", options: .regularExpression)
    return trimmed.replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
}

func parseHMS(_ value: String) -> Double? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    let parts = trimmed.split(separator: ":").map(String.init)
    guard parts.count == 3 else {
        return nil
    }

    guard
        let hours = Int(parts[0]),
        let minutes = Int(parts[1]),
        let seconds = Double(parts[2]),
        hours >= 0,
        minutes >= 0, minutes < 60,
        seconds >= 0, seconds < 60
    else {
        return nil
    }

    return Double(hours * 3600 + minutes * 60) + seconds
}

func formatShortSeconds(_ seconds: Double) -> String {
    String(format: "%.3fs", max(0.0, seconds))
}

func shellQuoted(_ value: String) -> String {
    if value.isEmpty {
        return "\"\""
    }

    let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._:-"))
    if value.rangeOfCharacter(from: safeCharacters.inverted) == nil {
        return value
    }

    return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func sanitizePrefix(_ value: String, fallback: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\\n\r\t")
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = trimmed.components(separatedBy: invalid).filter { !$0.isEmpty }
    let joined = pieces.joined(separator: "-")
    if !joined.isEmpty {
        return joined
    }

    let fallbackPieces = fallback.components(separatedBy: invalid).filter { !$0.isEmpty }
    if !fallbackPieces.isEmpty {
        return fallbackPieces.joined(separator: "-")
    }

    return "clip"
}

func makeOutputFileName(prefix: String, index: Int, pathExtension: String) -> String {
    let number = String(format: "%02d", index)
    let baseName = prefix.isEmpty ? number : "\(prefix)-\(number)"
    if pathExtension.isEmpty {
        return baseName
    }
    return "\(baseName).\(pathExtension)"
}

func buildEditableSegments(payload: DetectorPayload) -> [EditableSegment] {
    payload.keepSegments.map { segment in
        EditableSegment(
            index: segment.index,
            isEnabled: true,
            start: segment.start,
            end: segment.end
        )
    }
}

func buildJobs(segments: [EditableSegment], videoURL: URL, outputDirectoryURL: URL, prefix: String, crop: CropParameters?) -> [FFmpegJob] {
    let inputExtension = videoURL.pathExtension
    let fallbackPrefix = videoURL.deletingPathExtension().lastPathComponent
    let safePrefix = sanitizePrefix(prefix, fallback: fallbackPrefix)

    let enabledSegments = segments.filter { $0.isEnabled && $0.duration > 0 }

    return enabledSegments.enumerated().map { offset, segment in
        let outputIndex = offset + 1
        let fileName = makeOutputFileName(prefix: safePrefix, index: outputIndex, pathExtension: inputExtension)
        return FFmpegJob(
            index: outputIndex,
            inputURL: videoURL,
            outputURL: outputDirectoryURL.appendingPathComponent(fileName),
            start: segment.start,
            duration: segment.duration,
            crop: crop
        )
    }
}

func buildEventSummary(payload: DetectorPayload) -> String {
    var lines: [String] = []
    lines.append("视频: \(payload.video)")
    lines.append("检测到换场: \(payload.events.count)")
    lines.append("保留片段: \(payload.keepSegments.count)")
    lines.append("")

    if payload.events.isEmpty {
        lines.append("未检测到换场。")
        return lines.joined(separator: "\n")
    }

    for event in payload.events {
        lines.append(
            String(
                format: "%03d %@ start=%.3f end=%.3f duration=%.3f source=%@",
                event.index,
                event.type,
                event.start,
                event.end,
                event.duration,
                event.source
            )
        )
    }

    return lines.joined(separator: "\n")
}
