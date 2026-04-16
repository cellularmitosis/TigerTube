#!/usr/bin/env python3
# tigertube-proxy: transcoding proxy for the Tiger G3 TigerTube client.
#
# Exposes two raw-stream endpoints per video source. The client (TigerTube
# on a 600 MHz iMac G3) fetches video and audio as independent HTTP GETs.
# No container, no demuxer -- the server's ffmpeg emits raw elementary
# MPEG-1 video on /v/... and raw big-endian PCM on /a/... and that's all
# the client has to parse. Seek is a query parameter: the server re-spawns
# ffmpeg with `-ss T` and the client restarts both transfers.
#
# Endpoints:
#
#   GET /v/yt/<youtube_id>?t=&w=&h=&br=&fps=&g=
#   GET /v/file?path=<urlenc>&t=&w=&h=&br=&fps=&g=
#       -> raw MPEG-1 elementary video stream, no container
#
#   GET /a/yt/<youtube_id>?t=&rate=&ch=
#   GET /a/file?path=<urlenc>&t=&rate=&ch=
#       -> raw big-endian PCM s16 interleaved, no header
#
#   GET /probe/yt/<youtube_id>
#   GET /probe/file?path=<urlenc>
#       -> ffprobe JSON, for debugging
#
#   GET /  -> tiny index page listing the endpoints
#
# The "yt" variant runs yt-dlp to resolve the direct googlevideo URL (with
# a per-video-id cache good for ~5.5h, matching googlevideo's token TTL).
# The "file" variant takes a local path, which is handy for bring-up
# against local test sources without involving YouTube.

import os
import shlex
import subprocess
import time
from flask import Flask, Response, request, abort

app = Flask(__name__)

# --- config ---

PORT = 5002                                   # avoid 5001 used by test-server.py
CHUNK_SIZE = 16 * 1024                        # stdout read size

# default transcode parameters (chosen for 600 MHz G3 without AltiVec)
V_DEFAULT_W   = 320
V_DEFAULT_H   = 240
V_DEFAULT_BR  = "800k"
V_DEFAULT_FPS = 24
V_DEFAULT_G   = 12                            # GOP size; 12 @ 24fps = I-frame every 0.5s

A_DEFAULT_RATE = 44100
A_DEFAULT_CH   = 2

# --- yt-dlp URL cache (googlevideo tokens last ~5.5h) ---

YT_URL_TTL = 19800                            # 5h30m in seconds
_yt_cache = {}                                # id -> (url, timestamp)

def yt_resolve(youtube_id):
    """Resolve a YouTube ID to a direct googlevideo URL via yt-dlp.

    Caches per id for 5.5h. Picks best mp4 <=1080p to avoid grabbing raw
    4K that we'd then waste CPU rescaling server-side.
    """
    now = time.time()
    if youtube_id in _yt_cache:
        url, ts = _yt_cache[youtube_id]
        if now - ts < YT_URL_TTL:
            return url
    fmt = "best[height<=1080][ext=mp4]/best[height<=1080]"
    cmd = [
        "yt-dlp",
        "-f", fmt,
        "-g",
        f"https://www.youtube.com/watch?v={youtube_id}",
    ]
    print(f"--- yt-dlp: {' '.join(shlex.quote(a) for a in cmd)}", flush=True)
    try:
        url = subprocess.check_output(cmd, text=True).strip().splitlines()[0]
    except subprocess.CalledProcessError as e:
        print(f"--- yt-dlp failed: {e}", flush=True)
        abort(502, f"yt-dlp failed for {youtube_id}")
    _yt_cache[youtube_id] = (url, now)
    return url

# --- source resolution ---

def resolve_source(kind, ident):
    """kind: 'yt' or 'file'. Returns a URL/path ffmpeg can read."""
    if kind == "yt":
        return yt_resolve(ident)
    if kind == "file":
        # Resolve to absolute, require the file to exist.
        path = os.path.abspath(ident)
        if not os.path.isfile(path):
            abort(404, f"not a file: {path}")
        return path
    abort(400, f"unknown source kind: {kind}")

# --- ffmpeg command builders ---

def build_video_cmd(source, t, w, h, br, fps, g):
    """Build an ffmpeg command emitting raw MPEG-1 ES on stdout.

    The `setpts=PTS-STARTPTS` in the filter chain is load-bearing.
    YouTube's DASH-fragmented mp4 sources hand ffmpeg a first decoded
    frame whose PTS is ~5s into the timeline (fragment-start offset),
    not 0.  Without the setpts rebase, the subsequent `fps={fps}` CFR
    filter pads the first 5 seconds of output by duplicating that
    first frame (because "nearest input frame" for output-PTS 0..5s
    is always the one at input-PTS ~5s).  The client then sees the
    video frozen on the first frame for 5s while audio plays
    normally, and motion only resumes at output-time ~5s.  Rebasing
    PTS to zero before fps= makes output-PTS and input-PTS align.
    """
    return [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
        "-ss", f"{t}",
        "-i", source,
        "-an",
        "-sn",
        "-map", "0:v:0",
        "-vf", f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
               f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,"
               f"setpts=PTS-STARTPTS,"
               f"fps={fps}",
        "-c:v", "mpeg1video",
        "-b:v", br,
        "-maxrate", br,
        "-bufsize", f"{int(br.rstrip('k'))*2}k" if br.endswith('k') else br,
        "-g", f"{g}",
        "-force_key_frames", "0",
        "-f", "mpeg1video",
        "pipe:1",
    ]

def build_audio_cmd(source, t, rate, ch):
    """Build an ffmpeg command emitting raw s16be PCM on stdout."""
    return [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
        "-ss", f"{t}",
        "-i", source,
        "-vn",
        "-sn",
        "-map", "0:a:0",
        "-c:a", "pcm_s16be",
        "-ar", f"{rate}",
        "-ac", f"{ch}",
        "-f", "s16be",
        "pipe:1",
    ]

# --- streaming response helper ---

def stream_ffmpeg(cmd, mimetype):
    """Spawn ffmpeg, stream its stdout back to the HTTP client.

    Kills the subprocess on client disconnect (generator.close is called
    by Flask/Werkzeug when the peer drops).
    """
    print(f"--- spawn: {' '.join(shlex.quote(a) for a in cmd)}", flush=True)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    def generate():
        try:
            while True:
                data = proc.stdout.read(CHUNK_SIZE)
                if not data:
                    break
                yield data
        finally:
            if proc.poll() is None:
                try:
                    proc.kill()
                except Exception:
                    pass
            # Drain stderr so ffmpeg errors get logged.
            try:
                err = proc.stderr.read()
                if err:
                    print(f"--- ffmpeg stderr:\n{err.decode('utf-8', errors='replace')}",
                          flush=True)
            except Exception:
                pass
            proc.wait()

    return Response(generate(), mimetype=mimetype)

# --- param parsing ---

def parse_video_params():
    t   = float(request.args.get("t",   "0"))
    w   = int(request.args.get("w",     V_DEFAULT_W))
    h   = int(request.args.get("h",     V_DEFAULT_H))
    br  = request.args.get("br",        V_DEFAULT_BR)
    fps = int(request.args.get("fps",   V_DEFAULT_FPS))
    g   = int(request.args.get("g",     V_DEFAULT_G))
    return t, w, h, br, fps, g

def parse_audio_params():
    t    = float(request.args.get("t",    "0"))
    rate = int(request.args.get("rate",   A_DEFAULT_RATE))
    ch   = int(request.args.get("ch",     A_DEFAULT_CH))
    return t, rate, ch

# --- routes: video ---

@app.route("/v/yt/<youtube_id>")
def video_yt(youtube_id):
    t, w, h, br, fps, g = parse_video_params()
    src = resolve_source("yt", youtube_id)
    cmd = build_video_cmd(src, t, w, h, br, fps, g)
    return stream_ffmpeg(cmd, mimetype="video/mpeg")

@app.route("/v/file")
def video_file():
    path = request.args.get("path")
    if not path:
        abort(400, "missing path")
    t, w, h, br, fps, g = parse_video_params()
    src = resolve_source("file", path)
    cmd = build_video_cmd(src, t, w, h, br, fps, g)
    return stream_ffmpeg(cmd, mimetype="video/mpeg")

# --- routes: audio ---

@app.route("/a/yt/<youtube_id>")
def audio_yt(youtube_id):
    t, rate, ch = parse_audio_params()
    src = resolve_source("yt", youtube_id)
    cmd = build_audio_cmd(src, t, rate, ch)
    mime = f"audio/L16; rate={rate}; channels={ch}"
    return stream_ffmpeg(cmd, mimetype=mime)

@app.route("/a/file")
def audio_file():
    path = request.args.get("path")
    if not path:
        abort(400, "missing path")
    t, rate, ch = parse_audio_params()
    src = resolve_source("file", path)
    cmd = build_audio_cmd(src, t, rate, ch)
    mime = f"audio/L16; rate={rate}; channels={ch}"
    return stream_ffmpeg(cmd, mimetype=mime)

# --- routes: probe (debugging) ---

@app.route("/probe/yt/<youtube_id>")
def probe_yt(youtube_id):
    src = resolve_source("yt", youtube_id)
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", src,
    ], text=True)
    return Response(out, mimetype="application/json")

@app.route("/probe/file")
def probe_file():
    path = request.args.get("path")
    if not path:
        abort(400, "missing path")
    src = resolve_source("file", path)
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", src,
    ], text=True)
    return Response(out, mimetype="application/json")

# --- routes: index ---

@app.route("/")
def index():
    return Response(
        "tigertube-proxy\n"
        "\n"
        "Video (raw MPEG-1 elementary stream):\n"
        "  GET /v/yt/<id>?t=&w=&h=&br=&fps=&g=\n"
        "  GET /v/file?path=<abs>&t=&w=&h=&br=&fps=&g=\n"
        "\n"
        "Audio (raw s16be PCM):\n"
        "  GET /a/yt/<id>?t=&rate=&ch=\n"
        "  GET /a/file?path=<abs>&t=&rate=&ch=\n"
        "\n"
        "Probe (ffprobe JSON):\n"
        "  GET /probe/yt/<id>\n"
        "  GET /probe/file?path=<abs>\n"
        "\n"
        f"Defaults: video {V_DEFAULT_W}x{V_DEFAULT_H} @{V_DEFAULT_FPS}fps "
        f"{V_DEFAULT_BR} g={V_DEFAULT_G}; audio {A_DEFAULT_RATE}Hz "
        f"{A_DEFAULT_CH}ch s16be\n",
        mimetype="text/plain",
    )

# --- main ---

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT, threaded=True)
