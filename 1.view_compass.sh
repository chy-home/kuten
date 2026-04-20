#!/bin/bash

# 视频文件所在目录（请替换为你的实际目录）
VIDEO_DIR=$(pwd)
cd $VIDEO_DIR
mkdir out
mkdir del

# 遍历目录下的常见视频格式文件（可根据需要添加更多格式）
for video in "$VIDEO_DIR"/*.{mov,MOV,mp4,MP4,mkv,avi,flv,m4v}; do
    # 跳过不存在的文件（避免通配符不匹配时的错误）
    [ -f "$video" ] || continue

    # 获取文件名和路径（用于生成输出文件名）
    filename=$(basename "$video")
    extension="${filename##*.}"
    name="${filename%.*}"
    output="$VIDEO_DIR/out/${name}.${extension}"

    # 执行 ffmpeg 命令（保持音量不变，输出到新文件）
    ffmpeg -y -hide_banner -i "$video" -af "volume=1.0" "$output"
    mv "$video" del

    echo "处理完成：$output"
done
mv out/* ./
rm -rf out

echo "所有视频处理完毕！"