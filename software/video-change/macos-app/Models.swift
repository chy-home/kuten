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

    var displayName: String {
        switch self {
        case .conservative:
            return "保守"
        case .standard:
            return "标准"
        case .aggressive:
            return "激进"
        }
    }

    var pythonArgument: String {
        rawValue
    }

    var defaultPaddingSettings: FadePaddingSettings {
        switch self {
        case .conservative:
            return FadePaddingSettings(leftSeconds: 0.30, rightSeconds: 0.30)
        case .standard:
            return FadePaddingSettings(leftSeconds: 0.50, rightSeconds: 0.50)
        case .aggressive:
            return FadePaddingSettings(leftSeconds: 1.00, rightSeconds: 1.00)
        }
    }

    static let defaultValue: FadeRemovalStrategy = .standard

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

struct SelectableTransitionEvent {
    let event: TransitionEvent
    var isSelected: Bool
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
    var end: Double?
    var isManual: Bool
    var sourceKeepSegmentIndices: [Int]
    var isMergedFollower: Bool

    var isAutomatic: Bool {
        !sourceKeepSegmentIndices.isEmpty
    }

    var isUserToggleable: Bool {
        !isMergedFollower
    }

    func resolvedEnd(videoDuration: Double?) -> Double? {
        end ?? videoDuration
    }

    func containsSourceKeepSegment(index: Int) -> Bool {
        sourceKeepSegmentIndices.contains(index)
    }

    func duration(videoDuration: Double?) -> Double? {
        guard let resolvedEnd = resolvedEnd(videoDuration: videoDuration) else {
            return nil
        }
        return max(0.0, resolvedEnd - start)
    }

    func exportStartSeconds() -> Double {
        normalizeSegmentStartSeconds(start)
    }

    func exportResolvedEndSeconds(videoDuration: Double?) -> Double? {
        guard let resolvedEnd = resolvedEnd(videoDuration: videoDuration) else {
            return nil
        }
        return normalizeSegmentEndSeconds(resolvedEnd)
    }

    func exportDurationSeconds(videoDuration: Double?) -> Double? {
        guard let exportEnd = exportResolvedEndSeconds(videoDuration: videoDuration) else {
            return nil
        }
        return max(0.0, exportEnd - exportStartSeconds())
    }

    func shouldDefaultEnable(videoDuration: Double?) -> Bool {
        guard let duration = exportDurationSeconds(videoDuration: videoDuration) else {
            return true
        }
        return duration > 0
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

private let transitionValidationPaddingSeconds = 0.5

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

func formatOptionalHMS(_ seconds: Double?) -> String {
    guard let seconds else {
        return ""
    }
    return formatHMS(seconds)
}

func formatHMSWithoutMilliseconds(_ seconds: Double) -> String {
    let bounded = max(0.0, seconds)
    let roundedSeconds = Int(bounded.rounded())
    let hours = roundedSeconds / 3600
    let minutes = (roundedSeconds % 3600) / 60
    let secs = roundedSeconds % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, secs)
}

func formatOptionalHMSWithoutMilliseconds(_ seconds: Double?) -> String {
    guard let seconds else {
        return ""
    }
    return formatHMSWithoutMilliseconds(seconds)
}

func normalizeSegmentStartSeconds(_ seconds: Double) -> Double {
    max(0.0, ceil(max(0.0, seconds) - 0.000_000_001))
}

func normalizeSegmentEndSeconds(_ seconds: Double) -> Double {
    max(0.0, floor(max(0.0, seconds) + 0.000_000_001))
}

func formatSegmentStartHMS(_ seconds: Double) -> String {
    formatHMSWithoutMilliseconds(normalizeSegmentStartSeconds(seconds))
}

func formatOptionalSegmentEndHMS(_ seconds: Double?) -> String {
    guard let seconds else {
        return ""
    }
    return formatHMSWithoutMilliseconds(normalizeSegmentEndSeconds(seconds))
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

func makeOutputFileName(prefix: String, index: Int, totalCount: Int, pathExtension: String) -> String {
    let baseName: String
    if totalCount <= 1 {
        baseName = prefix.isEmpty ? "clip" : prefix
    } else {
        let number = String(format: "%02d", index)
        baseName = prefix.isEmpty ? number : "\(prefix)-\(number)"
    }
    if pathExtension.isEmpty {
        return baseName
    }
    return "\(baseName).\(pathExtension)"
}

func buildSelectableTransitionEvents(payload: DetectorPayload) -> [SelectableTransitionEvent] {
    payload.events.map { event in
        SelectableTransitionEvent(event: event, isSelected: true)
    }
}

func buildEditableSegments(payload: DetectorPayload) -> [EditableSegment] {
    payload.keepSegments.map { segment in
        let editable = EditableSegment(
            index: segment.index,
            isEnabled: true,
            start: segment.start,
            end: segment.end,
            isManual: false,
            sourceKeepSegmentIndices: [segment.index],
            isMergedFollower: false
        )
        return EditableSegment(
            index: editable.index,
            isEnabled: editable.shouldDefaultEnable(videoDuration: payload.duration),
            start: editable.start,
            end: editable.end,
            isManual: editable.isManual,
            sourceKeepSegmentIndices: editable.sourceKeepSegmentIndices,
            isMergedFollower: editable.isMergedFollower
        )
    }
}

func buildJobs(segments: [EditableSegment], videoURL: URL, outputDirectoryURL: URL, prefix: String, crop: CropParameters?, videoDuration: Double?) -> [FFmpegJob] {
    let inputExtension = videoURL.pathExtension
    let fallbackPrefix = videoURL.deletingPathExtension().lastPathComponent
    let safePrefix = sanitizePrefix(prefix, fallback: fallbackPrefix)

    let enabledSegments = segments.compactMap { segment -> (EditableSegment, Double)? in
        guard
            segment.isEnabled,
            let duration = segment.exportDurationSeconds(videoDuration: videoDuration),
            duration > 0
        else {
            return nil
        }
        return (segment, duration)
    }

    let totalCount = enabledSegments.count

    return enabledSegments.enumerated().map { offset, element in
        let segment = element.0
        let duration = element.1
        let outputIndex = offset + 1
        let fileName = makeOutputFileName(prefix: safePrefix, index: outputIndex, totalCount: totalCount, pathExtension: inputExtension)
        return FFmpegJob(
            index: outputIndex,
            inputURL: videoURL,
            outputURL: outputDirectoryURL.appendingPathComponent(fileName),
            start: segment.exportStartSeconds(),
            duration: duration,
            crop: crop
        )
    }
}

func buildTransitionValidationJobs(events: [TransitionEvent], payload: DetectorPayload, videoURL: URL, outputDirectoryURL: URL, prefix: String, crop: CropParameters?) -> [FFmpegJob] {
    let inputExtension = videoURL.pathExtension
    let fallbackPrefix = videoURL.deletingPathExtension().lastPathComponent
    let safePrefix = sanitizePrefix(prefix, fallback: fallbackPrefix)
    let validationPrefix = "\(safePrefix)-transition"

    let validEvents = events.compactMap { event -> (Double, Double)? in
        let start = max(0.0, event.start - transitionValidationPaddingSeconds)
        let end = min(payload.duration, event.end + transitionValidationPaddingSeconds)
        let duration = end - start
        guard duration > 0 else {
            return nil
        }
        return (start, duration)
    }

    let totalCount = validEvents.count

    return validEvents.enumerated().map { offset, range in
        let outputIndex = offset + 1
        let fileName = makeOutputFileName(prefix: validationPrefix, index: outputIndex, totalCount: totalCount, pathExtension: inputExtension)
        return FFmpegJob(
            index: outputIndex,
            inputURL: videoURL,
            outputURL: outputDirectoryURL.appendingPathComponent(fileName),
            start: range.0,
            duration: range.1,
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
