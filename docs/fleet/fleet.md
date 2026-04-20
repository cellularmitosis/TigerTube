# TigerTube PowerPC test fleet cheatsheet

Quick-reference hardware specs for the nine PowerPC Macs used to
develop and benchmark TigerTube. Sourced from
[everymac.com](https://everymac.com/); full snapshots live
alongside this file as `<url-slug>.html.mhtml` (view in a browser
that handles MHTML, e.g. Chrome, or extract HTML with `munpack`
etc).

## Access

All nine machines are reachable over ssh as `macuser`, key-based
auth (no password prompts). Hostnames are aliased in
`~/.ssh/config` on uranium (this laptop), so `ssh imacg3` etc.
just works.

Shared layout on each machine:

- `~/tmp/TigerTube/` — working copy. Source tree for Tiger hosts
  (rsync target of `tiger-rsync.sh` from uranium); built Debug/
  Release `.app` for fleet hosts (populated by `deploy-to-fleet.sh`).
- `/Users/macuser/tmp` — persistent scratch directory for logs.

Deploy a uniform build across the fleet with
`docs/features/decode-bench-harness/scripts/deploy-to-fleet.sh`
(builds on ibookg37 by default, rsyncs the Debug `.app` to every
other target via `tiger-rsync.sh`).

## Relevant environment skills

- **[imacg3-dev](../../.claude/skills/imacg3-dev/SKILL.md)**
  applies uniformly to every Tiger host in this fleet (pmacg3,
  imacg3, ibookg3, ibookg37, emac, imacg52). Same bash-3.2-too-old
  story, same stock `/usr/bin/curl` without modern TLS, same
  `/opt`-based modern toolchain bootstrapped by `tiger.sh`, same
  Xcode 2.5 + `MacOSX10.4u.sdk`, same `tiger-rsync.sh`
  `--protocol=27 --no-dirs` gotcha. The skill is named for imacg3
  because that was the primary dev-loop machine; the guidance is
  identical on the other Tiger boxes.
- **[leopard-adc-docs](../../.claude/skills/leopard-adc-docs/SKILL.md)**
  is the Apple API reference (ObjC 1.0, Carbon, Cocoa, QuickTime,
  Foundation, AppKit, 10.4/10.5 conceptual guides and sample code)
  — it applies to **any** TigerTube work targeting Tiger *or*
  Leopard, not just the two Leopard hosts. Reach for it on Cocoa
  / AppKit / Foundation API questions, availability checks, or
  when current developer.apple.com has removed a deprecated API.
- **`tiger-rsync.sh` is safe on Leopard too.** It lives on uranium;
  its `--protocol=27 --no-dirs` flags are Tiger-specific, but they
  don't harm Leopard. Use it uniformly for the whole fleet rather
  than branching on OS.

## The `/opt` modern-toolchain system

Every fleet host (Tiger and Leopard) has a helper script that
populates `/opt/<pkg>-<version>/` with binaries too new for the
host's stock OS:

- **Tiger hosts** use `tiger.sh`
- **Leopard hosts** use `leopard.sh`

Both scripts take the same shape:

```
tiger.sh             # (or leopard.sh) list available packages
tiger.sh foo-1.2.3   # install foo version 1.2.3 into /opt/foo-1.2.3
```

After install, both scripts **symlink `/opt/<pkg>-<ver>/{bin,sbin}/*`
into `/usr/local/{bin,sbin}/`** (which is on `macuser`'s PATH) — so
`foo` Just Works after `tiger.sh foo-1.2.3` without needing to
know or remember the versioned path.

**What's already installed on a given host varies** — it depends
on whichever project was last explored on that machine. Before
assuming `bash` 4+, modern `curl` with current TLS, `perl` 5.36,
a working `gcc` 4.9 / 10.3, etc. are present, either check
`ls /opt` on the target or just install what you need:

```
ssh <host> 'tiger.sh curl-8.5.0'        # on a Tiger host
ssh <host> 'leopard.sh curl-8.5.0'      # on a Leopard host
```

This is the intended workflow — you're free to install any of
the available packages on any host at any time. Nothing breaks
by adding `/opt` entries.

## Fleet hardware summary

Ordered by approximate generation / capability.

| Host | Machine | CPU | Clock | L1 | L2 | L3 | FSB | RAM type | GPU | VRAM | Native display |
|---|---|---|---|---|---|---|---|---|---|---|---|
| pmacg3 | Power Mac G3 B&W (1999) | PPC 750 | 400 MHz | 64 KB | 1 MB backside @ 200 MHz | — | 100 MHz | PC100 SDRAM | Rage 128 GL (66 MHz PCI) | 16 MB | external VGA |
| ibookg32 | iBook (Clamshell) 500 [**defunct**] | PPC 750 | 500 MHz | 64 KB | 256 KB on-chip | — | 66 MHz | PC100 SDRAM | Rage Mobility | 8 MB | 12.1" TFT 800×600 |
| imacg3 | iMac G3 Graphite (Summer 2001) | PPC 750cx | 600 MHz | 64 KB | 256 KB on-chip @ CPU speed | — | 100 MHz | PC100 SDRAM | Rage 128 Ultra (AGP 2X) | 16 MB | 15" CRT 800×600 |
| ibookg3 | iBook G3 Snow (12", mid-2002) | PPC 750fx | 900 MHz | 64 KB | 512 KB on-chip @ CPU speed | — | 100 MHz | PC100 SDRAM | Mobility Radeon 7500 | 32 MB | 12.1" TFT 1024×768 |
| ibookg37 | iBook G3 Snow (14", mid-2002) | PPC 750fx | 900 MHz | 64 KB | 512 KB on-chip @ CPU speed | — | 100 MHz | PC100 SDRAM | Mobility Radeon 7500 | 32 MB | 14.1" TFT 1024×768 |
| pbookg42 | PowerBook G4 Aluminum 15" | PPC 7447 | 1.25 GHz | 64 KB | 512 KB on-chip @ CPU speed | — | 167 MHz | PC2700 DDR | Mobility Radeon 9600 | 64 MB DDR | 15" 1280×854 |
| emac | eMac G4 1.42 (USB 2.0 / 2005) | PPC 7447a | 1.42 GHz | 64 KB | 512 KB on-chip @ CPU speed | — | 167 MHz | PC2700 DDR | Radeon 9600 | 64 MB DDR | 17" CRT |
| mdd | PowerMac G4 MDD 2×1.25 | PPC 7455 ×2 | 1.25 GHz (dual) | 64 KB (×2) | 256 KB on-chip @ CPU speed (×2) | **2 MB backside @ 4 GB/s** | 167 MHz | PC2700 DDR | Radeon 9000 Pro | 64 MB DDR | external |
| imacg52 | iMac G5 2.0 (20", 2004) | PPC 970 | 2.0 GHz | 32 KB D / 64 KB I | 512 KB on-chip @ CPU speed | — | 667 MHz (3:1) | PC3200 DDR | Radeon 9600 | 128 MB DDR | 20" TFT 1680×1050 |

All hosts run **Tiger (10.4)** except pbookg42 and mdd, which run
**Leopard (10.5)**. imacg52 supports AltiVec via its G5 core; all
G4 hosts (pbookg42, emac, mdd) have AltiVec; all G3 hosts do not.

ibookg32 entered a hardware wedge after one benchmark run and was
dropped from the study. Its row is kept here for completeness; do
not trust it for new measurements without first verifying the
machine comes back cleanly.

## Decode-bench ceilings (from [postmortem.md](../features/decode-bench-harness/postmortem.md))

| Host | Measured Mpx/s ceiling | Notes |
|---|---|---|
| pmacg3 | ~4.0 | Punches above its clock — 1 MB L2 keeps ref frames hot |
| imacg3 | ~3.5 | Small L2 + slot-loader constraints |
| ibookg3 / ibookg37 | ~5.2 each | 512 KB L2 + 900 MHz = the sweet spot for G3 |
| pbookg42 | ~34 | Sweeping AltiVec advantage, DDR memory |
| emac | ~31 | ~7% below pbookg42 despite 14% higher clock — memory subsystem favours pbookg42 |
| mdd | ~20 | Dual-core regression; thread migration trashes per-core L2 |
| imacg52 | ~60 | G5 + PC3200, only machine with visible headroom at 1600×1200 |

## Why the spec details matter (for reviewers of TigerTube perf work)

Insights from the decode-bench-harness study
([postmortem.md](../features/decode-bench-harness/postmortem.md)):

- **L2 cache size dominates G3 performance** at 480×360 and up.
  Two UYVY reference frames for motion compensation are ~690 KB at
  that geometry, so machines with ≥512 KB L2 (ibookg3, ibookg37)
  beat the 256 KB imacg3 despite otherwise-matched memory. pmacg3
  wins per-MHz with its 1 MB backside cache.
- **AltiVec (G4+) extracts ~4× more work per MHz** than G3.
  libmpeg2's IDCT and motion-compensation hot paths use AltiVec
  intrinsics; on G4s the decoder is no longer L2-bound and memory
  subsystem matters instead.
- **Dual-core is a trap for single-threaded decode** — mdd's two
  cores bounce the decoder thread between them, each migration
  dumping 256 KB of L2 state. The 2 MB L3 helps but doesn't save
  the ceiling. Single-core G4 at the same clock (pbookg42)
  sustains ~1.7× mdd's throughput.
- **G5 has 3× the bus speed** of any other fleet machine
  (667 MHz vs 167 MHz). Combined with PC3200 DDR, its memory
  subsystem absorbs every geometry in the sweep grid without
  breaking a sweat.

## Pointers

- Full spec pages: `*.html.mhtml` in this directory.
- Raw bench logs: `../features/decode-bench-harness/results/`.
- Postmortem with full analysis:
  `../features/decode-bench-harness/postmortem.md`.
- `imacg3-dev` skill: `../../.claude/skills/imacg3-dev/SKILL.md`.
