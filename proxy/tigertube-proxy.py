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
# For yt sources the proxy derives a source-height cap from the
# requested output height h= and asks yt-dlp for the smallest tier
# (YT_ALLOWED_SRC_HEIGHTS) that still covers it.
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
import shutil
import socket
import subprocess
import sys
import time
import http.server
import urllib.parse

# Bonjour / mDNS advertisement is required -- the TigerTube client has
# no manual-URL UI, so if we don't advertise, the client can't find us.
try:
    from zeroconf import ServiceInfo, Zeroconf
except ImportError:
    sys.stderr.write(
        "error: the 'zeroconf' python package is required.\n"
        "       install it with:  pip3 install zeroconf\n"
    )
    sys.exit(1)

# yt-dlp: resolves a YouTube ID to direct googlevideo URLs.  Used as a
# library (not a subprocess) so we can introspect the full format list
# and pick separate video-only and audio-only streams, letting the two
# endpoints fetch only what they need.
try:
    import yt_dlp
except ImportError:
    sys.stderr.write(
        "error: the 'yt-dlp' python package is required.\n"
        "       install it with:  pip3 install yt-dlp\n"
    )
    sys.exit(1)

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

# --- yt-dlp info cache (googlevideo tokens last ~5.5h) ---

YT_URL_TTL = 19800                            # 5h30m in seconds
_yt_cache = {}                                # id -> (info_dict, timestamp)

# yt-dlp impersonates one of YouTube's internal player clients to fetch
# the format list. Bot detection ("Sign in to confirm you're not a
# bot") is applied per-client: `web` is the most aggressively gated,
# while tv/embedded/mobile clients are often still cookie-free.
# yt-dlp tries these in order and falls back on failure. This list
# drifts as YouTube tightens enforcement -- if every request is hitting
# bot detection, check yt-dlp's GitHub issues for the current
# known-good clients.
#
# `android_vr` is load-bearing for the split-stream refactor: it's the
# only client in this set that currently returns separate video-only
# and audio-only DASH formats.  Without it, yt-dlp returns only
# combined HLS streams and pick_video_format/pick_audio_format fall
# back to downloading the same combined URL twice -- the exact
# bandwidth waste this refactor exists to fix.
YT_PLAYER_CLIENTS = ["tv_simply", "web_safari", "mweb", "android_vr"]

# Source-height cap tiers the proxy will request from yt-dlp.  Picked
# implicitly per request based on the client's requested output height
# (see compute_src_height): we pull the smallest source that still
# fully covers the output resolution, so a 320x240 G3 client never
# pays for a 1080p download.  Doesn't affect bot detection (that fires
# before format selection) but the cap saves yt-dlp response size,
# proxy bandwidth, and ffmpeg CPU.  Must stay sorted ascending.
YT_ALLOWED_SRC_HEIGHTS = (480, 720, 1080)
YT_DEFAULT_SRC_HEIGHT = 480

# --- http error plumbing ---

class HTTPError(Exception):
    """Raised by helpers to short-circuit with an HTTP error response.
    Caught by handle_request; the dispatcher turns it into a text/plain
    response with the given code."""
    def __init__(self, code, message):
        self.code = code
        self.message = message

def abort(code, message):
    raise HTTPError(code, message)

def compute_src_height(requested_h):
    """Pick the smallest allowed source tier that still covers the
    requested output height.  Omitted or non-positive heights (and
    audio / probe endpoints that have no output-resolution context)
    default to the lowest tier.  Heights above the highest tier are
    clamped -- there's nothing bigger to give them."""
    if requested_h is None or requested_h <= 0:
        return YT_DEFAULT_SRC_HEIGHT
    for tier in YT_ALLOWED_SRC_HEIGHTS:
        if requested_h <= tier:
            return tier
    return YT_ALLOWED_SRC_HEIGHTS[-1]

def yt_extract_info(youtube_id):
    """Extract the full yt-dlp info dict for a YouTube ID.

    Caches per id for 5.5h (googlevideo token TTL).  Callers then pick
    a video-only or audio-only URL out of info['formats'] so the two
    endpoints can fetch independent streams instead of downloading the
    full combined mp4 twice.
    """
    now = time.time()
    if youtube_id in _yt_cache:
        info, ts = _yt_cache[youtube_id]
        if now - ts < YT_URL_TTL:
            return info
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "extractor_args": {
            "youtube": {"player_client": YT_PLAYER_CLIENTS},
        },
    }
    url = f"https://www.youtube.com/watch?v={youtube_id}"
    print(f"--- yt-dlp: extract {youtube_id} "
          f"(player_client={','.join(YT_PLAYER_CLIENTS)})", flush=True)
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False, process=True)
    except yt_dlp.utils.DownloadError as e:
        print(f"--- yt-dlp failed: {e}", flush=True)
        abort(502, f"yt-dlp failed for {youtube_id}")
    _yt_cache[youtube_id] = (info, now)
    return info

def pick_video_format(info, src_h):
    """Pick the best video-only format URL with height <= src_h.

    Prefers mp4/h264 so ffmpeg's decoder stays on the fast path; falls
    back to whatever the best non-mp4 tier is (vp9/av1) if that's all
    the video exposes.

    Fallback for videos that only have combined (audio+video) formats
    -- e.g. YouTube Shorts, very old uploads: pick the best combined
    stream and log a warning.  The /a/yt/ endpoint will then use the
    same URL and we regress to today's double-download behavior for
    that video, but it still plays.
    """
    formats = info.get("formats") or []
    def vkey(f):
        return (1 if f.get("ext") == "mp4" else 0,
                f.get("height") or 0,
                f.get("tbr") or 0)
    video_only = [f for f in formats
                  if f.get("vcodec", "none") != "none"
                  and f.get("acodec", "none") == "none"
                  and (f.get("height") or 0) <= src_h
                  and f.get("url")]
    if video_only:
        return max(video_only, key=vkey)["url"]
    combined = [f for f in formats
                if f.get("vcodec", "none") != "none"
                and f.get("acodec", "none") != "none"
                and (f.get("height") or 0) <= src_h
                and f.get("url")]
    if combined:
        best = max(combined, key=vkey)
        print(f"--- pick_video_format: no video-only <={src_h}p for "
              f"{info.get('id')}, falling back to combined "
              f"{best.get('format_id')} ({best.get('ext')} "
              f"{best.get('height')}p)", flush=True)
        return best["url"]
    abort(502, f"no usable video format for {info.get('id')}")

def pick_audio_format(info):
    """Pick the best audio-only format URL.  Prefers m4a/AAC.

    Same combined-format fallback as pick_video_format for videos
    without split streams.
    """
    formats = info.get("formats") or []
    def akey(f):
        return (1 if f.get("ext") == "m4a" else 0,
                f.get("abr") or 0)
    audio_only = [f for f in formats
                  if f.get("vcodec", "none") == "none"
                  and f.get("acodec", "none") != "none"
                  and f.get("url")]
    if audio_only:
        return max(audio_only, key=akey)["url"]
    combined = [f for f in formats
                if f.get("vcodec", "none") != "none"
                and f.get("acodec", "none") != "none"
                and f.get("url")]
    if combined:
        # For combined fallback, sort by abr then prefer mp4.
        def ckey(f):
            return (1 if f.get("ext") == "mp4" else 0,
                    f.get("abr") or 0)
        best = max(combined, key=ckey)
        print(f"--- pick_audio_format: no audio-only for "
              f"{info.get('id')}, falling back to combined "
              f"{best.get('format_id')} ({best.get('ext')})",
              flush=True)
        return best["url"]
    abort(502, f"no usable audio format for {info.get('id')}")

# --- source resolution ---

# Extensions ffmpeg is allowed to demux from the /v/file and /a/file
# routes.  Lowercased, no leading dot.  This is a server-side guard --
# the client accepts any "file:<path>" spelling and we reject anything
# outside this list here, so a mistyped or malicious query can't ask
# ffmpeg to open e.g. a shell script or a password file.
_FILE_SOURCE_ALLOWED_EXTS = frozenset([
    "mp4", "m4v", "mov", "mkv", "avi",
    "mpg", "mpeg", "webm", "ogv", "ogm",
    "wmv", "flv", "ts", "m2ts", "mts",
    "3gp", "3g2",
])

def _resolve_file_source(ident):
    """Shared 'file' branch: expand ~, absolute-ize, assert existence,
    check ext.  expanduser() resolves relative to the proxy process's
    own $HOME, which is correct -- the file lives on this host, not
    the client's."""
    path = os.path.abspath(os.path.expanduser(ident))
    if not os.path.isfile(path):
        abort(404, f"not a file: {path}")
    ext = os.path.splitext(path)[1].lower().lstrip(".")
    if ext not in _FILE_SOURCE_ALLOWED_EXTS:
        abort(400, f"unsupported extension: .{ext}")
    return path

def resolve_video_source(kind, ident, src_h=YT_DEFAULT_SRC_HEIGHT):
    """kind: 'yt' or 'file'. Returns a URL/path ffmpeg can read as a
    video source.  For yt sources this is typically a DASH mp4
    video-only URL; the audio path is resolved separately so we don't
    download the combined mp4 twice.  src_h is only consulted for yt
    sources."""
    if kind == "yt":
        info = yt_extract_info(ident)
        return pick_video_format(info, src_h)
    if kind == "file":
        return _resolve_file_source(ident)
    abort(400, f"unknown source kind: {kind}")

def resolve_audio_source(kind, ident):
    """kind: 'yt' or 'file'. Returns a URL/path ffmpeg can read as an
    audio source.  For yt sources this is an audio-only stream
    (typically DASH m4a).  For file sources it's just the file -- the
    audio-extraction is done by ffmpeg in build_audio_cmd."""
    if kind == "yt":
        info = yt_extract_info(ident)
        return pick_audio_format(info)
    if kind == "file":
        return _resolve_file_source(ident)
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
    Quality mode: pass `q` (1-31, lower = better) and it overrides
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
           f"setpts=PTS-STARTPTS")
    # fps= CFR filter is opt-in: omit for source-rate passthrough.
    if fps is not None:
        vf += f",fps={fps}"
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

def stream_ffmpeg(handler, cmd, content_type):
    """Spawn ffmpeg, stream its stdout back to the HTTP client.

    Uses HTTP/1.0 semantics -- no Content-Length, connection close
    signals EOF.  Kills the subprocess on client disconnect (write to
    handler.wfile raises BrokenPipeError / ConnectionResetError when
    the peer drops).
    """
    print(f"--- spawn: {' '.join(shlex.quote(a) for a in cmd)}", flush=True)
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    try:
        handler.send_response(200)
        handler.send_header("Content-Type", content_type)
        handler.end_headers()
        while True:
            data = proc.stdout.read(CHUNK_SIZE)
            if not data:
                break
            try:
                handler.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                break
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

# --- http server plumbing ---

# Given '/foo?bar=42', return ('/foo', {'bar':'42'}).
def parse_GET_path(path_query):
    if '?' not in path_query:
        path_part = path_query
        query_dict = {}
    else:
        path_part, query_part = path_query.split('?', 1)
        query_dict = {}
        for k, v in urllib.parse.parse_qs(query_part).items():
            query_dict[k] = v[-1]
    while len(path_part) > 1 and path_part.endswith('/'):
        path_part = path_part[:-1]
    return path_part, query_dict

# Send a text response with Content-Length.  Used for index, errors,
# and probe JSON -- anything that isn't a live ffmpeg stream.
def send_text(handler, code, body, content_type="text/plain; charset=UTF-8"):
    if isinstance(body, str):
        data = body.encode("utf-8")
    else:
        data = body
    handler.send_response(code)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)

# Routing.  Static routes match an exact path; regex routes match the
# url_path against a compiled pattern.  Handlers parse their own path
# params out of handler.path (see GET_video_yt).
g_static_routes = {}
g_regex_routes = []

def add_static_route(http_method, url_path, fn):
    g_static_routes.setdefault(url_path, {})[http_method] = fn

def add_regex_route(http_method, label, regex, fn):
    g_regex_routes.append((http_method, label, regex, fn))

def route(handler):
    url_path, _ = parse_GET_path(handler.path)
    method = handler.command
    fn_dict = g_static_routes.get(url_path)
    if fn_dict:
        fn = fn_dict.get(method)
        if fn:
            return fn
    for method_i, _label, regex, fn in g_regex_routes:
        if method_i != method:
            continue
        if regex.match(url_path):
            return fn
    return None

def handle_request(handler):
    try:
        fn = route(handler)
        if fn is None:
            send_text(handler, 404, "Not Found\n")
            return
        fn(handler)
    except HTTPError as e:
        try:
            send_text(handler, e.code, f"{e.message}\n")
        except Exception:
            pass
    except (BrokenPipeError, ConnectionResetError):
        pass
    except Exception as e:
        try:
            send_text(handler, 500, f"Internal server error: {e}\n")
        except Exception:
            pass
        raise

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        handle_request(self)
    def do_HEAD(self):
        handle_request(self)

# --- param parsing ---

def parse_video_params(query_dict):
    t   = float(query_dict.get("t",   "0"))
    w   = int(query_dict.get("w",     V_DEFAULT_W))
    h   = int(query_dict.get("h",     V_DEFAULT_H))
    br  = query_dict.get("br",        V_DEFAULT_BR)
    # Missing fps => source rate: build_video_cmd will omit the
    # fps= CFR filter so frames pass through at their native
    # timing.  float() so that the proxy accepts fractional rates
    # (23.976, 29.97) from out-of-band curl callers, even though
    # the TigerTube client's popup only ships integers.
    fps_arg = query_dict.get("fps")
    fps = float(fps_arg) if fps_arg is not None else None
    g   = int(query_dict.get("g",     V_DEFAULT_G))
    # Quality mode is opt-in: only used when the client passes q=.
    # When present it overrides br= inside build_video_cmd.
    q_arg = query_dict.get("q")
    q = int(q_arg) if q_arg is not None else None
    # Crop is opt-in. Unset -> no crop. "auto" -> cropdetect probe
    # (cached per source). "W:H:X:Y" -> manual literal crop.
    crop_arg = query_dict.get("crop")
    return t, w, h, br, fps, g, q, crop_arg

def parse_audio_params(query_dict):
    t    = float(query_dict.get("t",    "0"))
    rate = int(query_dict.get("rate",   A_DEFAULT_RATE))
    ch   = int(query_dict.get("ch",     A_DEFAULT_CH))
    return t, rate, ch

# --- routes: video ---

def GET_video_yt(handler):
    url_path, q = parse_GET_path(handler.path)
    youtube_id = url_path.rsplit("/", 1)[1]
    t, w, h, br, fps, g, qv, crop_arg = parse_video_params(q)
    src_h = compute_src_height(h)
    src = resolve_video_source("yt", youtube_id, src_h=src_h)
    crop = resolve_crop(crop_arg, "yt", youtube_id, src)
    cmd = build_video_cmd(src, t, w, h, br, fps, g, qv, crop=crop)
    stream_ffmpeg(handler, cmd, content_type="video/mpeg")

add_regex_route(
    "GET",
    "/v/yt/:id",
    re.compile(r"^/v/yt/[A-Za-z0-9_-]+$"),
    GET_video_yt,
)

def GET_video_file(handler):
    _, q = parse_GET_path(handler.path)
    path = q.get("path")
    if not path:
        abort(400, "missing path")
    t, w, h, br, fps, g, qv, crop_arg = parse_video_params(q)
    src = resolve_video_source("file", path)
    crop = resolve_crop(crop_arg, "file", path, src)
    cmd = build_video_cmd(src, t, w, h, br, fps, g, qv, crop=crop)
    stream_ffmpeg(handler, cmd, content_type="video/mpeg")

add_static_route("GET", "/v/file", GET_video_file)

# --- routes: audio ---

def GET_audio_yt(handler):
    url_path, q = parse_GET_path(handler.path)
    youtube_id = url_path.rsplit("/", 1)[1]
    t, rate, ch = parse_audio_params(q)
    # Audio has no output-height context.  pick_audio_format picks the
    # best audio-only stream from the shared cached info dict, so a
    # concurrent video fetch on the same id reuses the same extract.
    src = resolve_audio_source("yt", youtube_id)
    cmd = build_audio_cmd(src, t, rate, ch)
    stream_ffmpeg(handler, cmd,
                  content_type=f"audio/L16; rate={rate}; channels={ch}")

add_regex_route(
    "GET",
    "/a/yt/:id",
    re.compile(r"^/a/yt/[A-Za-z0-9_-]+$"),
    GET_audio_yt,
)

def GET_audio_file(handler):
    _, q = parse_GET_path(handler.path)
    path = q.get("path")
    if not path:
        abort(400, "missing path")
    t, rate, ch = parse_audio_params(q)
    src = resolve_audio_source("file", path)
    cmd = build_audio_cmd(src, t, rate, ch)
    stream_ffmpeg(handler, cmd,
                  content_type=f"audio/L16; rate={rate}; channels={ch}")

add_static_route("GET", "/a/file", GET_audio_file)

# --- routes: probe (debugging) ---

def GET_probe_yt(handler):
    url_path, _ = parse_GET_path(handler.path)
    youtube_id = url_path.rsplit("/", 1)[1]
    src = resolve_video_source("yt", youtube_id, src_h=YT_DEFAULT_SRC_HEIGHT)
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", src,
    ], text=True)
    send_text(handler, 200, out, content_type="application/json")

add_regex_route(
    "GET",
    "/probe/yt/:id",
    re.compile(r"^/probe/yt/[A-Za-z0-9_-]+$"),
    GET_probe_yt,
)

def GET_probe_file(handler):
    _, q = parse_GET_path(handler.path)
    path = q.get("path")
    if not path:
        abort(400, "missing path")
    src = resolve_video_source("file", path)
    out = subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format",
        "-of", "json", src,
    ], text=True)
    send_text(handler, 200, out, content_type="application/json")

add_static_route("GET", "/probe/file", GET_probe_file)

# --- routes: index ---

def GET_index(handler):
    body = (
        "tigertube-proxy\n"
        "\n"
        "Video (raw MPEG-1 elementary stream):\n"
        "  GET /v/yt/<id>?t=&w=&h=&br=&fps=&g=&q=&crop=\n"
        "  GET /v/file?path=<abs>&t=&w=&h=&br=&fps=&g=&q=&crop=\n"
        "  (q=N uses constant-quality VBR and overrides br=; 1-31, lower=better)\n"
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
        f"{A_DEFAULT_CH}ch s16be.\n"
        f"yt source cap is derived from h=: picks the smallest of "
        f"{'/'.join(f'{v}p' for v in YT_ALLOWED_SRC_HEIGHTS)} that "
        f"still covers h.  Audio/probe use {YT_DEFAULT_SRC_HEIGHT}p.\n"
    )
    send_text(handler, 200, body)

add_static_route("GET", "/", GET_index)

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
    TigerTube client can auto-discover it on the LAN."""
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

# --- startup checks ---

def check_ffmpeg():
    """Verify ffmpeg is on PATH.  Every /v/... and /a/... request spawns
    ffmpeg, so without it the proxy serves nothing useful."""
    if shutil.which("ffmpeg") is not None:
        return
    if sys.platform == "darwin":
        hint = "install it with:  brew install ffmpeg"
    elif sys.platform.startswith("linux"):
        hint = ("install it with your distro's package manager, e.g.:\n"
                "         apt install ffmpeg      (debian/ubuntu)\n"
                "         dnf install ffmpeg      (fedora)\n"
                "         pacman -S ffmpeg        (arch)")
    else:
        hint = "install ffmpeg from https://ffmpeg.org/download.html"
    sys.stderr.write(
        "error: 'ffmpeg' was not found on PATH.\n"
        f"       {hint}\n"
    )
    sys.exit(1)

# --- main ---

if __name__ == "__main__":
    check_ffmpeg()
    zc, info = register_bonjour()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"--- listening on 0.0.0.0:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        zc.unregister_service(info)
        zc.close()
