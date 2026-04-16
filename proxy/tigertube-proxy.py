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
import re
import shlex
import socket
import subprocess
import time
from flask import Flask, Response, request, abort

# Bonjour / mDNS advertisement is optional -- proxy still works without it
# (clients fall back to manual URL).  `pip install zeroconf` to enable.
try:
    from zeroconf import ServiceInfo, Zeroconf
    _zeroconf_available = True
except ImportError:
    _zeroconf_available = False

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

# --- cropdetect: strip baked-in pillarbox/letterbox bars ---
#
# Some uploaders pillarbox 4:3 content into 16:9 uploads (classic example:
# old TV content, ripped-and-reposted clips). When our scale+pad chain
# then fits that into a 4:3 target resolution, the result has the
# original pillarbox still baked in AND our freshly-added letterbox --
# the "postage stamp" double-bars effect.
#
# Solution: probe a few seconds of the source with ffmpeg's cropdetect,
# parse the reported content bounds, and prepend `crop=W:H:X:Y` to the
# filter chain so the baked bars are gone before scale sees the frame.
# True 16:9 content cropdetects to the full frame -> crop is a no-op.
#
# Cost: ~3-5s of wall time on first play per video. Cached per source
# key so seeks don't re-probe. Content bounds don't change when a
# googlevideo URL expires and we re-resolve, so the cache has no TTL.

_crop_cache = {}                              # key -> crop_str or None

def source_key(kind, ident):
    """Stable cache key for a source. URL can change (googlevideo token
    expiry) but the content doesn't, so we key by kind+ident."""
    return f"{kind}:{ident}"

def detect_crop(source):
    """Probe a handful of frames to find content bounds. Returns a
    'W:H:X:Y' string if a non-trivial crop is needed, else None.

    `-ss 10` jumps past typical title cards / fade-ins so the probed
    frames are actual content, not a black opener (which would lie
    and tell us the whole frame is bars).

    `-frames:v 12` decodes just twelve frames (half a second at 24fps).
    cropdetect's `reset=0` accumulator keeps the max content bounds
    ever seen, so a few frames is plenty -- no need to decode seconds
    of video. The dominant cost left is the HTTP round-trip to
    googlevideo, not the decode itself.

    `-probesize`/`-analyzeduration` cap how much ffmpeg spends
    inspecting the MP4 container before starting to decode.
    """
    cmd = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "info",
        "-probesize", "1M",
        "-analyzeduration", "1M",
        "-ss", "10",
        "-i", source,
        "-frames:v", "12",
        "-an", "-sn",
        "-vf", "cropdetect=limit=16:round=2:reset=0",
        "-f", "null", "-",
    ]
    t0 = time.time()
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        print("--- cropdetect: timeout", flush=True)
        return None
    dt = time.time() - t0
    matches = re.findall(r'crop=(\d+):(\d+):(\d+):(\d+)', r.stderr)
    if not matches:
        print(f"--- cropdetect: no crop lines in output ({dt:.2f}s)",
              flush=True)
        return None
    w, h, x, y = matches[-1]
    crop = f"{w}:{h}:{x}:{y}"
    # If x and y are both 0, the detected bounds equal the full frame
    # (or at least don't start offset) -- no baked bars, skip the crop.
    if int(x) == 0 and int(y) == 0:
        print(f"--- cropdetect: full frame, skipping ({dt:.2f}s, {crop})",
              flush=True)
        return None
    print(f"--- cropdetect: {crop} ({dt:.2f}s)", flush=True)
    return crop

def get_crop(kind, ident, source):
    """Cached cropdetect. First call pays the probe cost; subsequent
    calls (including seeks) return instantly."""
    key = source_key(kind, ident)
    if key in _crop_cache:
        return _crop_cache[key]
    crop = detect_crop(source)
    _crop_cache[key] = crop
    print(f"--- crop for {key}: {crop}", flush=True)
    return crop

def resolve_crop(crop_arg, kind, ident, source):
    """Interpret the client's crop= query parameter.

    - None / empty     -> no crop (default; fast startup, may show baked
                          pillarbox+letterbox double-bars on pillarboxed
                          4:3-into-16:9 uploads).
    - "auto"           -> run cropdetect (cached). Slower first frame.
    - "W:H:X:Y"        -> use literal crop. Instant; client-supplied.
    - anything else    -> silently ignored (treat as no crop).
    """
    if not crop_arg:
        return None
    if crop_arg == "auto":
        return get_crop(kind, ident, source)
    if re.match(r'^\d+:\d+:\d+:\d+$', crop_arg):
        return crop_arg
    return None

# --- ffmpeg command builders ---

def build_video_cmd(source, t, w, h, br, fps, g, q, crop=None):
    """Build an ffmpeg command emitting raw MPEG-1 ES on stdout.

    Bitrate mode: pass `br` and leave `q` as None to get CBR-ish
    output with `-b:v / -maxrate / -bufsize`.
    Quality mode: pass `q` (2-31, lower = better) and it overrides
    the bitrate knobs with `-q:v N`, giving constant-quality VBR.
    Quality mode is preferred for LAN streaming where bandwidth
    isn't the bottleneck -- bitrate floats to what the content
    needs, avoiding pixelation spikes on high-motion frames.

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

    `-ss` is omitted entirely when t==0.  ffmpeg's HLS demuxer (which
    is what we get for YouTube format 301) logs "could not seek to
    position 0.000" for `-ss 0` and compensates by advancing past the
    first segment -- we lose the first ~5s of content.  Without `-ss`
    the demuxer just starts at the natural beginning.
    """
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
    ]
    if t > 0:
        cmd += ["-ss", f"{t}"]
    # Prepend crop= if we detected baked pillarbox/letterbox. Scale sees
    # the cropped content and fits it into the target, which our pad
    # then letterboxes normally if content aspect != target aspect.
    vf = ""
    if crop:
        vf += f"crop={crop},"
    vf += (f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
           f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,"
           f"setpts=PTS-STARTPTS,"
           f"fps={fps}")
    cmd += [
        "-i", source,
        "-an",
        "-sn",
        "-map", "0:v:0",
        "-vf", vf,
        "-c:v", "mpeg1video",
    ]
    if q is not None:
        cmd += ["-q:v", f"{q}"]
    else:
        cmd += [
            "-b:v", br,
            "-maxrate", br,
            "-bufsize", f"{int(br.rstrip('k'))*2}k" if br.endswith('k') else br,
        ]
    cmd += [
        "-g", f"{g}",
        "-force_key_frames", "0",
        "-f", "mpeg1video",
        "pipe:1",
    ]
    return cmd

def build_audio_cmd(source, t, rate, ch):
    """Build an ffmpeg command emitting raw s16be PCM on stdout.

    `-ss` omitted when t==0; see build_video_cmd comment for the HLS
    demuxer's "could not seek to position 0.000" misbehavior.
    """
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-hide_banner",
        "-loglevel", "warning",
    ]
    if t > 0:
        cmd += ["-ss", f"{t}"]
    cmd += [
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
    return cmd

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
    # Quality mode is opt-in: only used when the client passes q=.
    # When present it overrides br= inside build_video_cmd.
    q_arg = request.args.get("q")
    q = int(q_arg) if q_arg is not None else None
    # Crop is opt-in. Unset -> no crop. "auto" -> cropdetect probe
    # (cached per source). "W:H:X:Y" -> manual literal crop.
    crop_arg = request.args.get("crop")
    return t, w, h, br, fps, g, q, crop_arg

def parse_audio_params():
    t    = float(request.args.get("t",    "0"))
    rate = int(request.args.get("rate",   A_DEFAULT_RATE))
    ch   = int(request.args.get("ch",     A_DEFAULT_CH))
    return t, rate, ch

# --- routes: video ---

@app.route("/v/yt/<youtube_id>")
def video_yt(youtube_id):
    t, w, h, br, fps, g, q, crop_arg = parse_video_params()
    src = resolve_source("yt", youtube_id)
    crop = resolve_crop(crop_arg, "yt", youtube_id, src)
    cmd = build_video_cmd(src, t, w, h, br, fps, g, q, crop=crop)
    return stream_ffmpeg(cmd, mimetype="video/mpeg")

@app.route("/v/file")
def video_file():
    path = request.args.get("path")
    if not path:
        abort(400, "missing path")
    t, w, h, br, fps, g, q, crop_arg = parse_video_params()
    src = resolve_source("file", path)
    crop = resolve_crop(crop_arg, "file", path, src)
    cmd = build_video_cmd(src, t, w, h, br, fps, g, q, crop=crop)
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
        "  GET /v/yt/<id>?t=&w=&h=&br=&fps=&g=&q=&crop=\n"
        "  GET /v/file?path=<abs>&t=&w=&h=&br=&fps=&g=&q=&crop=\n"
        "  (q=N uses constant-quality VBR and overrides br=; 2-31, lower=better)\n"
        "  (crop=auto probes for baked pillarbox/letterbox bars; slower first frame.\n"
        "   crop=W:H:X:Y uses a literal crop rectangle. Omit for no crop.)\n"
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

# --- Bonjour advertisement ---

def _primary_local_ip():
    """Pick the IP that would be used to reach the LAN.  The UDP
    'connect' to an external IP doesn't send anything; it just makes
    the kernel select the outbound interface so we can read its
    address back.  Falls back to 127.0.0.1 if the LAN is offline."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()

def register_bonjour():
    """Advertise this proxy over mDNS as _tigertube-proxy._tcp, so the
    TigerTube client can auto-discover it on the LAN instead of needing
    a hardcoded URL.  No-op if the `zeroconf` package isn't installed."""
    if not _zeroconf_available:
        print("--- bonjour: zeroconf not installed, skipping advertisement "
              "(pip install zeroconf to enable)", flush=True)
        return None, None

    hostname = socket.gethostname().split(".")[0]
    ip = _primary_local_ip()
    info = ServiceInfo(
        type_="_tigertube-proxy._tcp.local.",
        name=f"TigerTube Proxy on {hostname}._tigertube-proxy._tcp.local.",
        addresses=[socket.inet_aton(ip)],
        port=PORT,
        server=f"{hostname}.local.",
    )
    zc = Zeroconf()
    zc.register_service(info)
    print(f"--- bonjour: advertised as '{info.name}' at {ip}:{PORT} "
          f"(server={info.server})", flush=True)
    return zc, info

# --- main ---

if __name__ == "__main__":
    zc, info = register_bonjour()
    try:
        app.run(host="0.0.0.0", port=PORT, threaded=True)
    finally:
        if zc is not None:
            zc.unregister_service(info)
            zc.close()
