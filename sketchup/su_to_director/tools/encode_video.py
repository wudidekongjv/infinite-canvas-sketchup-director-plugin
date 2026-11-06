#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把导演台回传的 PNG 序列编码成 mp4。

用法：
  python encode_video.py --dir "D:\\model\\su_director_export" --fps 24
  python encode_video.py --dir ... --fps 24 --pattern layer --out custom.mp4

目录约定（SU 插件自动创建）：
  <out_dir>/composite/composite_00000.png ...   ← 推荐，人物+SU 背景已经叠加好
  <out_dir>/layer/layer_00000.png ...           ← 只有人物，透明背景
  <out_dir>/bg/bg_00000.png ...                 ← SU 背景
  <out_dir>/video/*.mp4                         ← 输出
"""

import argparse
import glob
import os
import shutil
import subprocess
import sys
import time


def find_ffmpeg():
    exe = os.environ.get("SU_DIRECTOR_FFMPEG")
    if exe and os.path.isfile(exe):
        return exe
    which = shutil.which("ffmpeg")
    if which:
        return which
    try:
        import imageio_ffmpeg

        candidate = imageio_ffmpeg.get_ffmpeg_exe()
        if candidate and os.path.isfile(candidate):
            return candidate
    except Exception:
        pass
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", required=True, help="su_director_export 目录")
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--pattern", default="composite", choices=["composite", "layer", "bg"])
    parser.add_argument("--out", default=None, help="输出 mp4 路径，默认 video/composite_<fps>fps.mp4")
    parser.add_argument("--crf", type=int, default=18)
    parser.add_argument("--pix-fmt", default="yuv420p")
    args = parser.parse_args()

    frames = sorted(glob.glob(os.path.join(args.dir, args.pattern, "%s_*.png" % args.pattern)))
    if not frames:
        print("没有找到帧：%s" % os.path.join(args.dir, args.pattern, "%s_*.png" % args.pattern))
        return 2

    ffmpeg = find_ffmpeg()
    if not ffmpeg:
        print("找不到 ffmpeg。请安装 imageio-ffmpeg（pip install imageio-ffmpeg）或把 ffmpeg 加入 PATH。")
        return 3

    video_dir = os.path.join(args.dir, "video")
    os.makedirs(video_dir, exist_ok=True)
    out_path = args.out or os.path.join(video_dir, "%s_%dfps_%s.mp4" % (
        args.pattern, args.fps, time.strftime("%Y%m%d_%H%M%S")))

    input_pattern = os.path.join(args.dir, args.pattern, "%s_%%05d.png" % args.pattern)

    cmd = [
        ffmpeg, "-y",
        "-framerate", str(args.fps),
        "-start_number", "0",
        "-i", input_pattern,
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", str(args.crf),
        "-pix_fmt", args.pix_fmt,
        "-movflags", "+faststart",
        out_path,
    ]
    print("共 %d 帧，开始编码……" % len(frames))
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode != 0:
        print(result.stdout[-4000:])
        print("编码失败，返回码 %d" % result.returncode)
        return result.returncode
    print("完成：%s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
