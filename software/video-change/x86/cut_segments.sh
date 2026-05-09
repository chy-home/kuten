#!/usr/bin/env bash
set -euo pipefail

INPUT="test.mp4"
OUTDIR="test_clips"
mkdir -p "$OUTDIR"

ffmpeg -y -ss 00:00:01.280 -i "$INPUT" -t 00:00:00.280 -c:v libx264 -c:a aac "$OUTDIR/001_fade_1p28_1p56.mp4"
ffmpeg -y -ss 00:00:03.880 -i "$INPUT" -t 00:00:00.040 -c:v libx264 -c:a aac "$OUTDIR/002_cut_3p88_3p88.mp4"
ffmpeg -y -ss 00:00:06.040 -i "$INPUT" -t 00:00:00.040 -c:v libx264 -c:a aac "$OUTDIR/003_cut_6p04_6p04.mp4"
ffmpeg -y -ss 00:00:07.800 -i "$INPUT" -t 00:00:01.040 -c:v libx264 -c:a aac "$OUTDIR/004_black_7p8_8p84.mp4"
ffmpeg -y -ss 00:00:10.440 -i "$INPUT" -t 00:00:00.040 -c:v libx264 -c:a aac "$OUTDIR/005_cut_10p44_10p44.mp4"
