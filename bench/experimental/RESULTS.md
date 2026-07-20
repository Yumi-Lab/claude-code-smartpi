# Experimental: binary wire framing vs base64-in-JSON (daemon socket)

Validating replacing the daemon's base64-in-JSON output frames with length-prefixed
binary frames (`shim` daemon carries agent stdout/stderr; see `wire.mjs`). Bench:
`node bench/experimental/wire-bench.mjs` (8 KB chunks, integrity-checked).

## Smart Pi One (armv7l, Allwinner H3, Node 22, pinned to 1 core)

| output | proto | wire bytes | overhead | encode ms | decode ms |
|---|---|---|---|---|---|
| 64 KB | base64 | 87 688 | **+33.8%** | 4.06 | 2.65 |
| 64 KB | binary | 65 576 | **+0.1%** | **0.68** | **0.26** |
| 512 KB | base64 | 701 504 | +33.8% | 24.56 | 21.33 |
| 512 KB | binary | 524 608 | +0.1% | **5.23** | **1.42** |
| 4 MB | base64 | 5 612 032 | +33.8% | 178.6 | 130.4 |
| 4 MB | binary | 4 196 864 | +0.1% | **22.2** | **3.97** |

## Findings

- **Wire size** (deterministic): base64 adds a flat **+33.8%**; binary framing adds
  **+0.1%** (a 5-byte header per 8 KB chunk). Reliable, reproducible.
- **CPU** (deterministic, and the metric that matters on the weak H3): binary is
  **5–8× cheaper to encode** and **15–40× cheaper to decode**. On a 4 MB output the
  daemon spends ~179 ms just base64-encoding vs ~22 ms framing; the client ~130 ms
  decoding vs ~4 ms.
- **End-to-end wall** is a noisy proxy: binary wins clearly at 64 KB and 4 MB, but
  at 512 KB the two are within socket-scheduling noise (64 small writes dominate the
  timing, not the byte volume). Judge on wire + CPU, not e2e.
- **Integrity**: every case round-trips the exact byte count (`ok = yes`).

## Verdict

Binary framing is strictly better on the two reliable axes (bytes, CPU) with no
downside beyond a slightly less human-readable stream. The absolute per-job saving is
small for typical KB-scale answers, but real for verbose agents / large tool outputs
(multi-MB file reads, logs) where base64 transcode costs the H3 hundreds of ms.

**Status: experimental, validated — not yet wired into the production daemon.** To
promote: swap the daemon's `send`/output path and the client's decoder to `wire.mjs`
(negotiated per connection via a `wire:'bin'` flag on the run request, so old clients
keep the base64 path). Production `shim/claude-daemon.mjs` + `claude-client.mjs`
remain on base64 until then.
