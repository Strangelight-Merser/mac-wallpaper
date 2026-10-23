#!/usr/bin/env python3
"""Regenerate the self-made fixture using ffmpeg's software H.264 encoder."""
import pathlib
import struct
import subprocess
import tempfile

with tempfile.TemporaryDirectory() as folder:
    mp4 = pathlib.Path(folder) / "colors.mp4"
    subprocess.run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "color=c=red:s=16x16:r=2:d=1",
        "-f", "lavfi", "-i", "color=c=blue:s=16x16:r=2:d=1",
        "-filter_complex", "[0:v][1:v]concat=n=2:v=1:a=0[v]",
        "-map", "[v]", "-c:v", "libx264", "-g", "1", "-pix_fmt", "yuv420p", str(mp4)
    ], check=True)
    payload = mp4.read_bytes()


def words(*values):
    return struct.pack("<" + "i" * len(values), *values)


texture = (b"TEXV0005\0TEXI0001\0" + words(0, 34, 16, 16, 16, 16, 0)
           + b"TEXB0003\0" + words(1, -1, 1, 16, 16, 0, 0, len(payload)) + payload)
(pathlib.Path(__file__).parent / "materials/colors.tex").write_bytes(texture)
