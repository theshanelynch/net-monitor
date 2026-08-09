# net-monitor

A tiny, dependency-free internet health check for video calls and daily work.

It samples **latency**, **download**, and **upload** on an interval, draws a live
text chart, and reports **p50 / p90 / p99** for each metric plus a Google Meet
readiness verdict.

Pure macOS built-ins — `bash`, `curl`, `ping`, `awk`. **Nothing to install.**

## Usage

```bash
./net-monitor.sh                    # defaults: 20s run, 5s interval
./net-monitor.sh -d 90 -i 10        # 90-second run, sample every 10s
./net-monitor.sh --no-upload        # faster samples, skip the upload probe
./net-monitor.sh -H 8.8.8.8         # ping a different host
```

Press **Ctrl-C** any time to stop early — you still get the full summary.

## Options

| Flag | Default | Description |
| --- | --- | --- |
| `-d`, `--duration SEC` | `20` | total run time in seconds |
| `-i`, `--interval SEC` | `5` | seconds between samples |
| `-H`, `--host HOST` | `1.1.1.1` | host to ping for latency |
| `--dl-bytes N` | `8000000` | bytes to pull per download probe |
| `--ul-bytes N` | `3000000` | bytes to push per upload probe |
| `--no-upload` | off | skip the upload probe |
| `-h`, `--help` | | show help and exit |

## Output

- **Live view** — redraws every interval with the latest reading and a sparkline
  history for download, upload, and latency.
- **Summary** — printed on exit (and kept on screen). Sparkline graphs over time,
  a p50/p90/p99 table, and a readiness verdict. Each metric is judged on its
  **bad tail** — throughput on the **p10 floor**, latency on the **p90 ceiling**:
  - download ≥ 3.2 Mbps (p10 — 90% of the time you had at least this much)
  - upload ≥ 2.0 Mbps (p10)
  - latency ≤ 100 ms (p90 — near-worst reading)

  Thresholds live at the top of the script (`MEET_DL` / `MEET_UL` / `MEET_LAT`).

## How it works

Each sample runs three probes:

- **Latency** — 2 quick pings to `--host`, averaged (ms).
- **Download** — `curl` pulls `--dl-bytes` from Cloudflare's speed endpoint;
  throughput comes from curl's `speed_download` (Mbps).
- **Upload** — pushes `--ul-bytes` to Cloudflare's speed endpoint;
  throughput from curl's `speed_upload` (Mbps).

Every probe is capped at the sample interval so a stall can't overrun. Failed
probes are counted (`fails=`), not silently dropped. Percentiles use
nearest-rank; with only a handful of samples p90/p99 collapse toward the max, so
longer runs give more meaningful tails.

> **Note:** on a fast link, 8 MB downloads in a fraction of a second, so each
> probe measures a short burst rather than sustained load. For numbers closer to
> a full speedtest, raise the byte counts, e.g. `--dl-bytes 50000000`.
