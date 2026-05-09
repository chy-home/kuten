# AGENTS.md

## Project

This repository contains a native macOS video transition splitting tool with a GUI.

It detects and removes three transition types from a video:

- `cut`
- `fade`
- `black`

The current product is not just a CLI script. The main user-facing entry point is the AppKit app bundle:

- `VideoChange.app`

The detection engine is still implemented in Python:

- `detect_scene_changes.py`

The default validation asset is:

- `test.mp4`

## Current Architecture

- `macos-app/`
  Swift + AppKit desktop UI
- `detect_scene_changes.py`
  Python detector invoked by the macOS app
- `build_macos_app.sh`
  builds `VideoChange.app`

The app supports:

- selecting a video file
- selecting or editing the output directory
- output naming with `prefix-01.ext`
- parsing scene transitions
- showing transition rows and editable keep segments
- splitting kept segments with adjustable concurrency
- drag/drop for file and directory paths
- crop input in `w:h:x:y` format
- skip-start detection seconds
- fade removal strategy selection
- per-strategy manual left/right fade padding seconds
- per-segment enable/disable
- per-segment editable start/end time
- a master checkbox for bulk enable/disable of all split segments

## Runtime

- macOS app runtime:
  - Swift / AppKit
  - `ffmpeg` installed and reachable
  - Python virtualenv available at `.venv`
- Python runtime:
  - `.venv/bin/python`
- Python libraries currently used by the detector:
  - `numpy`
  - `scenedetect` / PySceneDetect

This project is no longer dependency-free on the Python side.

## Main Files

- `detect_scene_changes.py`
  detector, JSON output, fade strategy logic
- `macos-app/MainWindowController.swift`
  main window UI and user interaction flow
- `macos-app/Services.swift`
  subprocess bridge to Python detector
- `macos-app/Models.swift`
  payload models, output naming, ffmpeg job generation
- `macos-app/WorkerWindowController.swift`
  ffmpeg worker log windows
- `macos-app/AppMain.swift`
  app startup and menu
- `build_macos_app.sh`
  app bundling script

## Fade Strategy

Fade removal is configurable in four levels:

- `conservative`
- `standard`
- `aggressive`
- `extreme`

UI labels:

- `保守`
- `标准`
- `激进`
- `极激进`

Each strategy has two layers of behavior:

1. detection-side fade boundary settling profile
2. removal-side manual padding:
   - left padding seconds
   - right padding seconds

The GUI currently exposes the manual padding seconds for every strategy directly.

Current default padding values in Swift and Python must stay aligned:

- `conservative`: left `0.04`, right `0.12`
- `standard`: left `0.08`, right `0.18`
- `aggressive`: left `0.12`, right `0.24`
- `extreme`: left `0.16`, right `0.32`

Important intent:

- left side should not be overly aggressive
- right side should not be overly conservative
- user may manually tune both values per strategy

## Detection Strategy

- `cut`
  cross-validated with ffmpeg scene scores and PySceneDetect cut detectors
- `black`
  detected with ffmpeg `blackdetect`, then expanded with RGB/luma checks
- `fade`
  detected with low-resolution RGB frame analysis, grayscale direction checks, and adaptive boundary settling

The detector outputs:

- transition events
- keep segments
- JSON payload for the app

The generated ffmpeg commands keep normal scenes and delete transition ranges.

## FFmpeg Job Format

The current split job format must stay aligned with the GUI segment table.

Each enabled keep segment becomes one ffmpeg job in this shape:

```bash
ffmpeg -y -hide_banner -ss <start-seconds> -i "<input>" -t <duration-seconds> -strict -2 [-vf crop=w:h:x:y] "<output>"
```

Important details:

- `-ss` appears before `-i`
- `-t` appears after `-i`
- `start-seconds` comes from the editable segment start time
- `duration-seconds` is computed from `end - start`
- GUI time fields are shown as `HH:MM:SS.mmm`
- ffmpeg arguments use trimmed second values such as `34`, `34.4`, or `34.422`
- the current job generator no longer injects `setpts`, explicit `-map`, or forced x264 keyframe parameters
- output file extension remains the same as the source video extension

## UI Notes

The current fade control is a radio-button group, not a popup:

- one radio button per fade strategy
- editable left/right second fields per strategy

The split segment area is no longer a raw ffmpeg script text view.

- it is a table of keep segments
- columns are `启用`, `开始时间`, `结束时间`
- rows remain visible even when disabled
- disabled rows do not generate ffmpeg jobs
- editing start/end time changes the real split job
- clicking a transition row should still highlight related keep-segment rows
- the title area contains a master checkbox labeled `全选`
- the master checkbox supports all-on, all-off, and mixed state

When changing the selected fade strategy or its padding values:

- if the video has already been parsed, the app should re-run parsing
- the result table and segment table should refresh to the new strategy

## Build

Build the app:

```bash
./build_macos_app.sh
```

Run the built app:

```bash
open "/Users/cyril/git/video-change/VideoChange.app"
```

## Validation

Detector JSON check:

```bash
./.venv/bin/python detect_scene_changes.py test.mp4 --json
```

App self-test:

```bash
./VideoChange.app/Contents/MacOS/VideoChange --self-test
```

App detector summary:

```bash
./VideoChange.app/Contents/MacOS/VideoChange --detect-summary test.mp4
```

Useful fade validation example:

```bash
./.venv/bin/python detect_scene_changes.py test.mp4 --json --fade-removal-profile aggressive --fade-left-padding-seconds 0.12 --fade-right-padding-seconds 0.24
```

## Editing Notes

- Use `apply_patch` for code edits.
- Do not revert unrelated user changes.
- Keep Swift-side default fade padding values aligned with Python-side defaults.
- Keep UI labels and Python argument values aligned for fade strategy names.
- Worker-window command preview and actual ffmpeg execution arguments must match.
- The segment table is the source of truth for split jobs; manual edits must flow into execution.
- The master segment checkbox state must stay synced with individual segment rows.
- `crop` must remain a single string input in `w:h:x:y` format.
- `skip-start-seconds` support must be preserved end-to-end.
- Worker windows should continue to show ffmpeg progress logs.

## Current Expected Behavior

For `test.mp4`, the detector should currently find:

- one fade near `1.5s`
- cuts near `3.88`, `6.04`, `10.44`
- one black transition around `7.76-8.84`

For the default `aggressive` fade padding:

- left padding is lighter than the previous build
- right padding is stronger than the previous build

If fade behavior is changed, verify both:

- the `1.5s` fade no longer leaves visible trailing transition content
- normal content is not excessively removed on the left side
