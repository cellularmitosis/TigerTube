## Architecture

The playback pipeline is three concurrent actors plus a 30 Hz display
timer on the main thread:

1. **Video fetch thread** — libcurl → libmpeg2 → 3-slot UYVY frame queue.
2. **Audio fetch thread** — libcurl → 256 KB s16be ring buffer.
3. **CoreAudio render callback** — drains the ring, converts to Float32.
4. **Display timer** — non-blocking dequeue, `glTexSubImage2D` with
   `GL_YCBCR_422_APPLE`, draws a letterboxed quad.

The A/V clock is the audio sample counter; the video decoder paces itself
to stay ~40 ms ahead of it. TCP backpressure on the video socket throttles
ffmpeg on the proxy end so the G3 is never ahead of itself.

On the proxy side, each client request spawns an `ffmpeg` that emits
**raw elementary streams** — MPEG-1 video on `/v/...`, raw big-endian
PCM on `/a/...`. No container, no demuxer on the client. Seek is a
query parameter (`?t=SECONDS`); the client restarts both transfers.

