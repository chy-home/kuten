#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


RGBMean = tuple[float, float, float]


@dataclass
class Event:
    kind: str
    start: float
    end: float
    score: float
    source: str


@dataclass(frozen=True)
class FadeRemovalProfile:
    name: str
    settle_backtrack_seconds: float
    settle_forward_seconds: float
    low_diff_threshold: float
    stable_diff_threshold: float
    stable_luma_delta: float
    stable_run_frames: int


FADE_REMOVAL_PROFILES: dict[str, FadeRemovalProfile] = {
    "conservative": FadeRemovalProfile(
        name="conservative",
        settle_backtrack_seconds=0.12,
        settle_forward_seconds=0.16,
        low_diff_threshold=0.0195,
        stable_diff_threshold=0.0215,
        stable_luma_delta=0.65,
        stable_run_frames=1,
    ),
    "standard": FadeRemovalProfile(
        name="standard",
        settle_backtrack_seconds=0.18,
        settle_forward_seconds=0.24,
        low_diff_threshold=0.0185,
        stable_diff_threshold=0.0205,
        stable_luma_delta=0.55,
        stable_run_frames=1,
    ),
    "aggressive": FadeRemovalProfile(
        name="aggressive",
        settle_backtrack_seconds=0.24,
        settle_forward_seconds=0.32,
        low_diff_threshold=0.0175,
        stable_diff_threshold=0.0195,
        stable_luma_delta=0.45,
        stable_run_frames=2,
    ),
    "extreme": FadeRemovalProfile(
        name="extreme",
        settle_backtrack_seconds=0.32,
        settle_forward_seconds=0.44,
        low_diff_threshold=0.0165,
        stable_diff_threshold=0.0185,
        stable_luma_delta=0.38,
        stable_run_frames=3,
    ),
}


def resolve_fade_removal_profile(name: str) -> FadeRemovalProfile:
    profile = FADE_REMOVAL_PROFILES.get(name)
    if profile is None:
        raise ValueError(f"unsupported fade removal profile: {name}")
    return profile


def round_time(value: float) -> float:
    return round(max(0.0, value), 3)


def log_progress(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def format_hms(seconds: float) -> str:
    seconds = max(0.0, seconds)
    whole = int(seconds)
    millis = int(round((seconds - whole) * 1000))
    if millis == 1000:
        whole += 1
        millis = 0
    hours = whole // 3600
    minutes = (whole % 3600) // 60
    secs = whole % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def probe_video_info(video_path: Path) -> tuple[float, float]:
    proc = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(video_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    stderr = proc.stderr

    fps = 25.0
    for pattern in (
        r",\s*([0-9]+(?:\.[0-9]+)?)\s*fps,",
        r",\s*([0-9]+(?:\.[0-9]+)?)\s*tbr,",
    ):
        match = re.search(pattern, stderr)
        if match:
            parsed = float(match.group(1))
            if parsed > 0:
                fps = parsed
                break

    duration_match = re.search(r"Duration:\s*([0-9]{2}):([0-9]{2}):([0-9]{2}(?:\.[0-9]+)?)", stderr)
    if not duration_match:
        raise RuntimeError("failed to parse video duration")
    duration = (
        int(duration_match.group(1)) * 3600
        + int(duration_match.group(2)) * 60
        + float(duration_match.group(3))
    )
    return fps, duration


def run_text_command(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "command failed")
    return f"{proc.stdout}\n{proc.stderr}"


def ffmpeg_seek_args(skip_start_seconds: float) -> list[str]:
    if skip_start_seconds <= 0:
        return []
    return ["-ss", format_hms(skip_start_seconds)]


def read_scene_scores(video_path: Path, width: int, height: int, skip_start_seconds: float) -> list[float]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        *ffmpeg_seek_args(skip_start_seconds),
        "-i",
        str(video_path),
        "-an",
        "-vf",
        f"scale={width}:{height},format=gray,select='gte(scene,0)',metadata=mode=print:file=-",
        "-f",
        "null",
        "-",
    ]
    output = run_text_command(cmd)
    scores = [float(match.group(1)) for match in re.finditer(r"lavfi\.scene_score=([0-9]+(?:\.[0-9]+)?)", output)]
    if not scores:
        raise RuntimeError("failed to parse ffmpeg scene scores")
    return scores


def read_black_regions(video_path: Path, threshold: float, min_seconds: float, skip_start_seconds: float) -> list[tuple[float, float]]:
    pix_threshold = max(0.0, min(1.0, threshold / 255.0))
    cmd = [
        "ffmpeg",
        "-hide_banner",
        *ffmpeg_seek_args(skip_start_seconds),
        "-i",
        str(video_path),
        "-vf",
        f"blackdetect=d={min_seconds}:pix_th={pix_threshold:.4f}",
        "-an",
        "-f",
        "null",
        "-",
    ]
    output = run_text_command(cmd)
    pattern = r"black_start:([0-9]+(?:\.[0-9]+)?)\s+black_end:([0-9]+(?:\.[0-9]+)?)\s+black_duration:([0-9]+(?:\.[0-9]+)?)"
    return [(float(m.group(1)), float(m.group(2))) for m in re.finditer(pattern, output)]


def group_runs(indices: list[int], max_gap: int = 1) -> list[tuple[int, int]]:
    if not indices:
        return []
    runs: list[tuple[int, int]] = []
    start = prev = indices[0]
    for index in indices[1:]:
        if index <= prev + max_gap:
            prev = index
            continue
        runs.append((start, prev))
        start = prev = index
    runs.append((start, prev))
    return runs


def luma_value(rgb: RGBMean) -> float:
    red, green, blue = rgb
    return 0.299 * red + 0.587 * green + 0.114 * blue


def normalized_color_delta(left: RGBMean, right: RGBMean) -> float:
    return sum(abs(a - b) for a, b in zip(left, right)) / (255.0 * 3.0)


def color_direction_consistency(rgb_means: list[RGBMean], start: int, end: int) -> tuple[float, float]:
    consistencies: list[float] = []
    for channel in range(3):
        signed = 0.0
        total = 0.0
        for index in range(start + 1, end + 1):
            delta = rgb_means[index][channel] - rgb_means[index - 1][channel]
            signed += delta
            total += abs(delta)
        if total >= 1.0:
            consistencies.append(abs(signed) / total)
    if not consistencies:
        return 0.0, 0.0
    return max(consistencies), statistics.fmean(consistencies)


def is_inside_regions(frame_index: int, fps: float, regions: list[tuple[float, float]], padding_frames: int = 2) -> bool:
    frame_time = frame_index / fps
    padding = padding_frames / fps
    for start, end in regions:
        if start - padding <= frame_time <= end + padding:
            return True
    return False


def read_rgb_stats(video_path: Path, width: int, height: int, skip_start_seconds: float) -> tuple[list[RGBMean], list[float], list[object]]:
    try:
        import numpy as np
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(f"NumPy unavailable: {exc}") from exc

    pixels = width * height
    frame_size = pixels * 3
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        *ffmpeg_seek_args(skip_start_seconds),
        "-i",
        str(video_path),
        "-an",
        "-vf",
        f"scale={width}:{height},format=rgb24",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "pipe:1",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None

    means: list[RGBMean] = []
    diffs: list[float] = []
    gray_frames: list[object] = []
    prev_frame = None
    frames_read = 0
    progress_interval = 2500

    try:
        while True:
            chunk = proc.stdout.read(frame_size)
            if len(chunk) < frame_size:
                break

            frame = np.frombuffer(chunk, dtype=np.uint8).reshape((height, width, 3))
            red_mean, green_mean, blue_mean = frame.mean(axis=(0, 1))
            means.append((float(red_mean), float(green_mean), float(blue_mean)))

            gray = (
                (
                    frame[:, :, 0].astype(np.uint16) * 77
                    + frame[:, :, 1].astype(np.uint16) * 150
                    + frame[:, :, 2].astype(np.uint16) * 29
                )
                >> 8
            ).astype(np.int16)
            gray_frames.append(gray)

            if prev_frame is None:
                diffs.append(0.0)
            else:
                diffs.append(float(np.abs(frame.astype(np.int16) - prev_frame).mean() / 255.0))
            prev_frame = frame
            frames_read += 1
            if frames_read % progress_interval == 0:
                log_progress(f"[detect] RGB frames read: {frames_read}")
    finally:
        stderr = proc.stderr.read() if proc.stderr is not None else b""
        ret = proc.wait()
        if ret != 0:
            raise RuntimeError(stderr.decode("utf-8", "replace").strip() or "ffmpeg failed")

    return means, diffs, gray_frames


def grayscale_direction_metrics(gray_frames: list[object], start: int, end: int) -> tuple[float, float]:
    try:
        import numpy as np
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(f"NumPy unavailable: {exc}") from exc

    if end <= start + 1:
        return 0.0, 0.0

    endpoint_delta = gray_frames[end] - gray_frames[start]
    mask = np.abs(endpoint_delta) >= 5
    if not np.any(mask):
        return 0.0, 0.0

    masked_endpoint = endpoint_delta[mask].astype(np.float32)
    endpoint_norm = float(np.linalg.norm(masked_endpoint))
    if endpoint_norm <= 1e-6:
        return 0.0, 0.0

    endpoint_sign = np.sign(masked_endpoint)
    sign_scores: list[float] = []
    corr_scores: list[float] = []

    for index in range(start + 1, end + 1):
        step_delta = gray_frames[index] - gray_frames[index - 1]
        masked_step = step_delta[mask].astype(np.float32)
        step_norm = float(np.linalg.norm(masked_step))
        if step_norm <= 1e-6:
            continue
        sign_scores.append(float((np.sign(masked_step) == endpoint_sign).mean()))
        corr_scores.append(float(np.dot(masked_step, masked_endpoint) / (step_norm * endpoint_norm)))

    if not sign_scores:
        return 0.0, 0.0

    return statistics.fmean(sign_scores), statistics.fmean(corr_scores)


def settle_fade_boundaries(
    start: int,
    end: int,
    rgb_means: list[RGBMean],
    rgb_diffs: list[float],
    fps: float,
    profile: FadeRemovalProfile,
) -> tuple[int, int]:
    max_backtrack = max(2, int(round(profile.settle_backtrack_seconds * fps)))
    max_forward = max(3, int(round(profile.settle_forward_seconds * fps)))

    adjusted_start = start
    steps = 0
    while adjusted_start > 1 and steps < max_backtrack:
        local_diff = rgb_diffs[adjusted_start]
        local_luma_delta = abs(luma_value(rgb_means[adjusted_start]) - luma_value(rgb_means[adjusted_start - 1]))
        if local_diff <= profile.low_diff_threshold and local_luma_delta <= profile.stable_luma_delta:
            break
        adjusted_start -= 1
        steps += 1

    adjusted_end = end
    settle_run = 0
    steps = 0
    while adjusted_end < len(rgb_diffs) - 2 and steps < max_forward:
        next_index = adjusted_end + 1
        local_diff = rgb_diffs[next_index]
        local_luma_delta = abs(luma_value(rgb_means[next_index]) - luma_value(rgb_means[adjusted_end]))
        if local_diff <= profile.stable_diff_threshold and local_luma_delta <= profile.stable_luma_delta:
            settle_run += 1
            adjusted_end = next_index
            steps += 1
            if settle_run >= profile.stable_run_frames:
                break
            continue

        settle_run = 0
        adjusted_end = next_index
        steps += 1

    return adjusted_start, adjusted_end


def run_pyscenedetect_detectors(video_path: Path, width: int, height: int, fps: float, skip_start_seconds: float) -> dict[str, list[int]]:
    try:
        import numpy as np
        from scenedetect.detectors import AdaptiveDetector, ContentDetector, ThresholdDetector
    except Exception as exc:  # pragma: no cover
        raise RuntimeError(f"PySceneDetect unavailable: {exc}") from exc

    frame_size = width * height * 3
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        *ffmpeg_seek_args(skip_start_seconds),
        "-i",
        str(video_path),
        "-an",
        "-vf",
        f"scale={width}:{height},format=rgb24",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "pipe:1",
    ]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout is not None

    content = ContentDetector(threshold=27.0, min_scene_len=max(5, int(round(0.16 * fps))))
    adaptive = AdaptiveDetector(
        adaptive_threshold=2.0,
        min_scene_len=max(5, int(round(0.16 * fps))),
        window_width=2,
        min_content_val=8.0,
    )
    threshold = ThresholdDetector(threshold=12, min_scene_len=max(2, int(round(0.08 * fps))), fade_bias=0.0)

    content_cuts: list[int] = []
    adaptive_cuts: list[int] = []
    threshold_cuts: list[int] = []
    progress_interval = 2500

    frame_num = 0
    try:
        while True:
            chunk = proc.stdout.read(frame_size)
            if len(chunk) < frame_size:
                break
            frame = np.frombuffer(chunk, dtype=np.uint8).reshape((height, width, 3))
            content_cuts.extend(content.process_frame(frame_num, frame))
            adaptive_cuts.extend(adaptive.process_frame(frame_num, frame))
            threshold_cuts.extend(threshold.process_frame(frame_num, frame))
            frame_num += 1
            if frame_num > 0 and frame_num % progress_interval == 0:
                log_progress(f"[detect] PySceneDetect frames processed: {frame_num}")
    finally:
        stderr = proc.stderr.read() if proc.stderr is not None else b""
        ret = proc.wait()
        if ret != 0:
            raise RuntimeError(stderr.decode("utf-8", "replace").strip() or "ffmpeg failed")

    return {
        "content": content_cuts,
        "adaptive": adaptive_cuts,
        "threshold": threshold_cuts,
    }


def detect_cut_events(scene_scores: list[float], pyscene_cuts: dict[str, list[int]], fps: float, blocked_regions: list[tuple[float, float]], cut_threshold: float) -> list[Event]:
    strong_ffmpeg = {
        index
        for index, score in enumerate(scene_scores)
        if index > 0 and score >= cut_threshold and not is_inside_regions(index, fps, blocked_regions, padding_frames=2)
    }
    cross_validated = set(pyscene_cuts["content"]) & set(pyscene_cuts["adaptive"])
    cut_frames = sorted(index for index in (strong_ffmpeg | cross_validated) if not is_inside_regions(index, fps, blocked_regions, padding_frames=2))

    events: list[Event] = []
    for start, end in group_runs(cut_frames, max_gap=1):
        peak_index = max(range(start, end + 1), key=lambda idx: scene_scores[idx] if idx < len(scene_scores) else 0.0)
        events.append(Event("cut", peak_index / fps, peak_index / fps, scene_scores[peak_index], "ffmpeg+pyscenedetect"))
    return events


def detect_black_events(
    rgb_means: list[RGBMean],
    rgb_diffs: list[float],
    fps: float,
    black_regions: list[tuple[float, float]],
    threshold_cuts: list[int],
) -> list[Event]:
    events: list[Event] = []
    threshold_set = set(threshold_cuts)
    for black_start, black_end in black_regions:
        center_start = max(0, int(round(black_start * fps)))
        center_end = min(len(rgb_means) - 1, int(round(black_end * fps)))

        start = center_start
        while start > 1:
            if rgb_diffs[start] < 0.020 and luma_value(rgb_means[start]) > 62:
                break
            start -= 1
            if center_start - start > int(0.6 * fps):
                break

        end = center_end
        while end < len(rgb_means) - 2:
            if rgb_diffs[end + 1] < 0.020 and luma_value(rgb_means[end]) > 42:
                break
            end += 1
            if end - center_end > int(0.45 * fps):
                break

        if any(start <= cut <= end for cut in threshold_set):
            score = sum(rgb_diffs[start : end + 1]) + 0.2
        else:
            score = sum(rgb_diffs[start : end + 1])
        events.append(Event("black", start / fps, (end + 1) / fps, score, "ffmpeg+threshold"))
    return events


def detect_fade_events(
    scene_scores: list[float],
    rgb_means: list[RGBMean],
    rgb_diffs: list[float],
    gray_frames: list[object],
    fps: float,
    blocked_regions: list[tuple[float, float]],
    cut_events: list[Event],
    min_fade_seconds: float,
    fade_threshold: float,
    fade_profile: FadeRemovalProfile,
) -> list[Event]:
    min_frames = max(7, int(round(min_fade_seconds * fps)))
    max_frames = max(min_frames + 2, int(round(0.6 * fps)))
    cut_indices = {int(round(event.start * fps)) for event in cut_events}
    candidates: list[Event] = []

    for window_size in range(min_frames, max_frames + 1):
        for start in range(0, len(rgb_means) - window_size + 1):
            end = start + window_size - 1
            if is_inside_regions(start, fps, blocked_regions, padding_frames=4) or is_inside_regions(end, fps, blocked_regions, padding_frames=4):
                continue
            if any(start <= cut_index + 3 and end >= cut_index - 3 for cut_index in cut_indices):
                continue

            diff_segment = rgb_diffs[start : end + 1]
            mean_diff = statistics.fmean(diff_segment)
            median_diff = statistics.median(diff_segment)
            peak_diff = max(diff_segment)
            if mean_diff < fade_threshold or median_diff < fade_threshold * 0.82 or peak_diff >= 0.08:
                continue

            variation = statistics.pstdev(diff_segment) / mean_diff if len(diff_segment) > 1 and mean_diff else 0.0
            if variation > 0.26:
                continue

            local_scene_peak = max(scene_scores[start : end + 1])
            if local_scene_peak >= 0.11:
                continue

            color_delta = normalized_color_delta(rgb_means[start], rgb_means[end])
            luma_delta = abs(luma_value(rgb_means[end]) - luma_value(rgb_means[start])) / 255.0
            direction_max, direction_avg = color_direction_consistency(rgb_means, start, end)
            cumulative_diff = sum(diff_segment)
            if color_delta < 0.040 and luma_delta < 0.042:
                continue
            if direction_max < 0.92 or direction_avg < 0.88:
                continue
            if cumulative_diff < 0.20:
                continue

            pixel_direction_agreement, pixel_direction_corr = grayscale_direction_metrics(gray_frames, start, end)
            if pixel_direction_agreement < 0.66 or pixel_direction_corr < 0.30:
                continue

            adjusted_start, adjusted_end = settle_fade_boundaries(start, end, rgb_means, rgb_diffs, fps, fade_profile)

            score = (
                mean_diff * 8.0
                + color_delta * 1.2
                + luma_delta * 1.2
                + direction_avg
                + pixel_direction_agreement
                + pixel_direction_corr
                - variation
                - len(diff_segment) * 0.015
            )
            candidates.append(Event("fade", adjusted_start / fps, (adjusted_end + 1) / fps, score, "custom"))

    candidates.sort(key=lambda event: event.score, reverse=True)
    events: list[Event] = []
    for candidate in candidates:
        overlaps = any(not (candidate.end <= event.start or candidate.start >= event.end) for event in events)
        if overlaps:
            continue
        events.append(candidate)
    return events


def merge_overlaps(events: list[Event]) -> list[Event]:
    if not events:
        return []
    ordered = sorted(events, key=lambda event: (event.start, event.end, event.kind))
    merged = [ordered[0]]
    for event in ordered[1:]:
        current = merged[-1]
        if event.kind == current.kind and event.start <= current.end:
            current.end = max(current.end, event.end)
            current.score = max(current.score, event.score)
            current.source = current.source + "+" + event.source
        else:
            merged.append(event)
    return merged


def event_to_dict(event: Event, index: int) -> dict[str, object]:
    return {
        "index": index,
        "type": event.kind,
        "start": round_time(event.start),
        "end": round_time(event.end),
        "duration": round_time(event.end - event.start),
        "score": round(event.score, 4),
        "source": event.source,
    }


def expanded_event_range(
    event: Event,
    duration: float,
    fps: float,
    aggressive: bool,
    fade_profile: FadeRemovalProfile,
    fade_left_padding_seconds: float,
    fade_right_padding_seconds: float,
) -> tuple[float, float]:
    frame = 1.0 / fps if fps > 0 else 0.04
    if aggressive:
        if event.kind == "cut":
            extra_before = frame * 4
            extra_after = frame * 4
        elif event.kind == "fade":
            extra_before = max(0.0, fade_left_padding_seconds)
            extra_after = max(0.0, fade_right_padding_seconds)
        else:
            extra_before = frame * 3
            extra_after = frame * 5
    else:
        if event.kind == "cut":
            extra_before = 0.0
            extra_after = 0.0
        elif event.kind == "fade":
            extra_before = max(frame, fade_left_padding_seconds * 0.8)
            extra_after = max(frame, fade_right_padding_seconds * 0.8)
        else:
            extra_before = frame
            extra_after = frame

    start = max(0.0, event.start - extra_before)
    end = event.end
    if end <= event.start:
        end = min(duration, event.start + frame)
    end = min(duration, end + extra_after)
    return start, end


def complement_segments(
    events: list[Event],
    duration: float,
    fps: float,
    aggressive: bool,
    fade_profile: FadeRemovalProfile,
    fade_left_padding_seconds: float,
    fade_right_padding_seconds: float,
    minimum_start_seconds: float = 0.0,
) -> list[tuple[float, float]]:
    frame = 1.0 / fps if fps > 0 else 0.04
    removal: list[tuple[float, float]] = []
    for event in events:
        removal.append(
            expanded_event_range(
                event,
                duration,
                fps,
                aggressive,
                fade_profile,
                fade_left_padding_seconds,
                fade_right_padding_seconds,
            )
        )

    merged: list[tuple[float, float]] = []
    for start, end in sorted(removal):
        if not merged or start > merged[-1][1]:
            merged.append((start, end))
        else:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))

    kept: list[tuple[float, float]] = []
    cursor = max(0.0, min(minimum_start_seconds, duration))
    for start, end in merged:
        if start > cursor:
            kept.append((cursor, start))
        cursor = max(cursor, end)
    if cursor < duration:
        kept.append((cursor, duration))

    return [(round_time(start), round_time(end)) for start, end in kept if end - start >= frame]


def print_keep_commands(video_path: Path, segments: list[tuple[float, float]]) -> None:
    for index, (start, end) in enumerate(segments, start=1):
        duration = max(0.0, end - start)
        if duration <= 0:
            continue
        output_name = f"{video_path.stem}_keep_{index:03d}_{str(start).replace('.', 'p')}_{str(end).replace('.', 'p')}.mp4"
        print(
            f'ffmpeg -y -ss {format_hms(start)} -i "{video_path}" -t {format_hms(duration)} '
            f'-c:v libx264 -c:a aac "{output_name}"'
        )


def detect_scene_changes(
    video_path: Path,
    width: int,
    height: int,
    black_threshold: float,
    min_black_seconds: float,
    min_fade_seconds: float,
    cut_threshold: float,
    fade_threshold: float,
    skip_start_seconds: float,
    fade_profile: FadeRemovalProfile,
    fade_left_padding_seconds: float,
    fade_right_padding_seconds: float,
) -> tuple[float, float, list[Event]]:
    fps, duration = probe_video_info(video_path)
    log_progress(f"[detect] Video opened: fps={round(fps, 3)} duration={round(duration, 3)}s")
    analysis_start = max(0.0, min(skip_start_seconds, duration))
    log_progress(f"[detect] Analysis starts at {round(analysis_start, 3)}s")
    log_progress("[detect] Reading RGB frame stats...")
    rgb_means, rgb_diffs, gray_frames = read_rgb_stats(video_path, width, height, analysis_start)
    log_progress(f"[detect] RGB frame stats ready: {len(rgb_means)} frames")
    log_progress("[detect] Reading ffmpeg scene scores...")
    scene_scores = read_scene_scores(video_path, width, height, analysis_start)
    log_progress(f"[detect] Scene scores ready: {len(scene_scores)} frames")
    log_progress("[detect] Running PySceneDetect detectors...")
    pyscene_cuts = run_pyscenedetect_detectors(video_path, width, height, fps, analysis_start)
    log_progress(
        "[detect] PySceneDetect ready: "
        f"content={len(pyscene_cuts['content'])} adaptive={len(pyscene_cuts['adaptive'])} threshold={len(pyscene_cuts['threshold'])}"
    )
    log_progress("[detect] Reading black regions...")
    black_regions = read_black_regions(video_path, black_threshold, min_black_seconds, analysis_start)
    log_progress(f"[detect] Black regions ready: {len(black_regions)}")

    frame_count = min(len(rgb_means), len(rgb_diffs), len(gray_frames), len(scene_scores))
    rgb_means = rgb_means[:frame_count]
    rgb_diffs = rgb_diffs[:frame_count]
    gray_frames = gray_frames[:frame_count]
    scene_scores = scene_scores[:frame_count]

    black_events = detect_black_events(rgb_means, rgb_diffs, fps, black_regions, pyscene_cuts["threshold"])
    log_progress(f"[detect] Black events: {len(black_events)}")
    blocked_regions = [(event.start, event.end) for event in black_events]
    cut_events = detect_cut_events(scene_scores, pyscene_cuts, fps, blocked_regions, cut_threshold)
    log_progress(f"[detect] Cut events: {len(cut_events)}")
    fade_events = detect_fade_events(
        scene_scores=scene_scores,
        rgb_means=rgb_means,
        rgb_diffs=rgb_diffs,
        gray_frames=gray_frames,
        fps=fps,
        blocked_regions=blocked_regions,
        cut_events=cut_events,
        min_fade_seconds=min_fade_seconds,
        fade_threshold=fade_threshold,
        fade_profile=fade_profile,
    )
    log_progress(f"[detect] Fade events: {len(fade_events)}")
    events = merge_overlaps(black_events + cut_events + fade_events)
    if analysis_start > 0:
        for event in events:
            event.start += analysis_start
            event.end += analysis_start
    events.sort(key=lambda event: (event.start, event.end, event.kind))
    log_progress(f"[detect] Final merged events: {len(events)}")
    return fps, duration, events


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Cross-validated scene transition detector using ffmpeg + PySceneDetect detectors.")
    parser.add_argument("video", nargs="?", default="test.mp4", help="Video path (default: test.mp4)")
    parser.add_argument("--width", type=int, default=160, help="Analysis width")
    parser.add_argument("--height", type=int, default=90, help="Analysis height")
    parser.add_argument("--black-threshold", type=float, default=18.0, help="Black pixel threshold on a 0-255 scale")
    parser.add_argument("--min-black-seconds", type=float, default=0.08, help="Minimum black core duration")
    parser.add_argument("--min-fade-seconds", type=float, default=0.28, help="Minimum fade duration")
    parser.add_argument("--cut-threshold", type=float, default=0.15, help="Cut threshold on ffmpeg scene_score scale")
    parser.add_argument("--fade-threshold", type=float, default=0.022, help="Fade threshold on low-res RGB frame-diff scale")
    parser.add_argument(
        "--fade-removal-profile",
        choices=sorted(FADE_REMOVAL_PROFILES.keys()),
        default="aggressive",
        help="How aggressively fade transitions are removed",
    )
    parser.add_argument("--fade-left-padding-seconds", type=float, default=None, help="Additional fade removal before fade start")
    parser.add_argument("--fade-right-padding-seconds", type=float, default=None, help="Additional fade removal after fade end")
    parser.add_argument("--skip-start-seconds", type=float, default=0.0, help="Skip this many seconds from the beginning before detection")
    parser.add_argument("--aggressive", action="store_true", default=True, help="Expand removal ranges to avoid keeping any transition edges")
    parser.add_argument("--no-aggressive", action="store_false", dest="aggressive", help="Use tighter removal ranges")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary")
    args = parser.parse_args(argv)

    video_path = Path(args.video)
    if not video_path.exists():
        print(f"video not found: {video_path}", file=sys.stderr)
        return 2

    fade_profile = resolve_fade_removal_profile(args.fade_removal_profile)
    default_padding = {
        "conservative": (0.04, 0.12),
        "standard": (0.08, 0.18),
        "aggressive": (0.12, 0.24),
        "extreme": (0.16, 0.32),
    }
    default_left_padding, default_right_padding = default_padding[fade_profile.name]
    fade_left_padding_seconds = default_left_padding if args.fade_left_padding_seconds is None else max(0.0, args.fade_left_padding_seconds)
    fade_right_padding_seconds = default_right_padding if args.fade_right_padding_seconds is None else max(0.0, args.fade_right_padding_seconds)

    fps, duration, events = detect_scene_changes(
        video_path=video_path,
        width=args.width,
        height=args.height,
        black_threshold=args.black_threshold,
        min_black_seconds=args.min_black_seconds,
        min_fade_seconds=args.min_fade_seconds,
        cut_threshold=args.cut_threshold,
        fade_threshold=args.fade_threshold,
        skip_start_seconds=args.skip_start_seconds,
        fade_profile=fade_profile,
        fade_left_padding_seconds=fade_left_padding_seconds,
        fade_right_padding_seconds=fade_right_padding_seconds,
    )

    payload_events = [event_to_dict(event, index + 1) for index, event in enumerate(events)]
    kept_segments = complement_segments(
        events,
        duration,
        fps,
        args.aggressive,
        fade_profile,
        fade_left_padding_seconds,
        fade_right_padding_seconds,
        minimum_start_seconds=max(0.0, min(args.skip_start_seconds, duration)),
    )
    payload = {
        "video": str(video_path),
        "fps": round(fps, 3),
        "duration": round_time(duration),
        "skip_start_seconds": round_time(args.skip_start_seconds),
        "aggressive": args.aggressive,
        "fade_removal_profile": fade_profile.name,
        "fade_left_padding_seconds": round_time(fade_left_padding_seconds),
        "fade_right_padding_seconds": round_time(fade_right_padding_seconds),
        "events": payload_events,
        "keep_segments": [
            {
                "index": index + 1,
                "start": start,
                "end": end,
                "duration": round_time(end - start),
            }
            for index, (start, end) in enumerate(kept_segments)
        ],
    }

    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    for event in payload_events:
        print(
            f'{event["index"]:03d} {event["type"]} start={event["start"]:.3f} '
            f'end={event["end"]:.3f} duration={event["duration"]:.3f} source={event["source"]}'
        )

    print("")
    print("# Keep normal scenes:")
    print_keep_commands(video_path, kept_segments)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
