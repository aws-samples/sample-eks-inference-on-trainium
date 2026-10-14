#!/usr/bin/env python3
r"""Summarize inference-perf benchmark results from S3, endpoints side by side.

For each target label it reads the latest run under s3://<bucket>/benchmarks/<label>/:
  target.json                                  cost basis (hourlyUsd from the Helm values)
  chat-latency/<run>/summary_lifecycle_metrics.json
  chat-throughput/<run>/stage_<n>_lifecycle_metrics.json

and prints:
  1. Latency at 1 req/s: TTFT, TPOT and request latency (client-side, p50/p95)
  2. Throughput sweep: per load stage, achieved rate, output tokens/s, TTFT and
     TPOT - where latency bends is where the endpoint saturates
  3. Cost/performance at the peak stage: output tokens per $, $ per 1M output tokens

Usage:
  benchmark/visualize.py --bucket "$S3_BUCKET_NAME" \
      --targets gpt-oss-20b-trn2-48xl gpt-oss-20b-p5-48xl \
      [--hourly-usd gpt-oss-20b-trn2-48xl=<usd/hr> ...]   # overrides target.json

Requires the AWS CLI on PATH with credentials that can read the bucket.
"""
import argparse
import json
import re
import subprocess
import sys

# Region for all S3 calls, from the bucket's location (avoids 301s when the CLI
# default region differs).
_REGION: str | None = None


def _aws(*args: str) -> str:
    cmd = ["aws", *args] + (["--region", _REGION] if _REGION else [])
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def resolve_region(bucket: str) -> str:
    """The bucket's region (us-east-1 reports an empty LocationConstraint)."""
    out = _aws("s3api", "get-bucket-location", "--bucket", bucket,
               "--query", "LocationConstraint", "--output", "text").strip()
    return "us-east-1" if out in ("", "None", "null") else out


def s3_json(bucket: str, key: str) -> dict | None:
    try:
        return json.loads(_aws("s3", "cp", f"s3://{bucket}/{key}", "-"))
    except subprocess.CalledProcessError:
        return None


def latest_run(bucket: str, label: str, test: str) -> dict[str, str]:
    """{file name: key} of the most recent run of one test (newest summary file wins)."""
    try:
        listing = _aws("s3", "ls", f"s3://{bucket}/benchmarks/{label}/{test}/", "--recursive")
    except subprocess.CalledProcessError:
        return {}
    files = [(f"{p[0]} {p[1]}", p[-1]) for p in (l.split() for l in listing.splitlines()) if len(p) >= 4]
    summaries = sorted(f for f in files if f[1].endswith("summary_lifecycle_metrics.json"))
    if not summaries:
        return {}
    run_dir = summaries[-1][1].rsplit("/", 1)[0]
    return {k.rsplit("/", 1)[1]: k for _, k in files if k.rsplit("/", 1)[0] == run_dir}


def ms(summary: dict | None, key: str) -> str:
    return "-" if not summary else f"{summary[key] * 1000:.0f}"


def print_table(title: str, header: list[str], rows: list[list[str]]) -> None:
    print(f"\n{title}")
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header))]
    fmt = lambda r: "  ".join(c.ljust(w) if i == 0 else c.rjust(w) for i, (c, w) in enumerate(zip(r, widths)))
    print(fmt(header))
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print(fmt(r))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bucket", required=True, help="S3 results bucket name")
    ap.add_argument("--targets", nargs="+", required=True, metavar="LABEL", help="benchmark target labels")
    ap.add_argument("--hourly-usd", nargs="*", default=[], metavar="LABEL=USD",
                    help="override a target's $/hr (default: hourlyUsd from its target.json)")
    args = ap.parse_args()
    if not args.bucket:
        ap.error("--bucket is empty; check that $S3_BUCKET_NAME is exported.")
    overrides = dict(o.split("=", 1) for o in args.hourly_usd)

    global _REGION
    _REGION = resolve_region(args.bucket)

    latency_rows, verdict_rows = [], []
    for label in args.targets:
        target = s3_json(args.bucket, f"benchmarks/{label}/target.json") or {}
        usd = float(overrides.get(label, target.get("hourlyUsd") or 0))

        # 1. Latency at 1 req/s
        lat = latest_run(args.bucket, label, "chat-latency")
        s = (s3_json(args.bucket, lat["summary_lifecycle_metrics.json"]) or {}).get("successes") if lat else None
        l = s["latency"] if s else {}
        latency_rows.append([
            label,
            ms(l.get("time_to_first_token"), "median"), ms(l.get("time_to_first_token"), "p95"),
            ms(l.get("time_per_output_token"), "median"), ms(l.get("time_per_output_token"), "p95"),
            ms(l.get("request_latency"), "median"),
        ])

        # 2. Throughput sweep, stage by stage
        thr = latest_run(args.bucket, label, "chat-throughput")
        stages = sorted(
            (int(re.search(r"stage_(\d+)_", f).group(1)), s3_json(args.bucket, k))
            for f, k in thr.items() if re.match(r"stage_\d+_lifecycle_metrics\.json", f)
        )
        rows, peak = [], None
        for n, st in stages:
            if not st:
                continue
            succ, load = st["successes"], st["load_summary"]
            tps = succ["throughput"]["output_tokens_per_sec"]
            fails = st.get("failures", {}).get("count", 0)
            rows.append([
                str(n), f"{load.get('requested_rate', 0):.2f}", f"{load.get('achieved_rate', 0):.2f}",
                f"{tps:.0f}", ms(succ["latency"].get("time_to_first_token"), "median"),
                ms(succ["latency"].get("time_to_first_token"), "p95"),
                ms(succ["latency"].get("time_per_output_token"), "median"), str(fails),
            ])
            if fails == 0 and (peak is None or tps > peak[1]):
                peak = (n, tps)
        if rows:
            print_table(f"THROUGHPUT SWEEP - {label}  (ShareGPT, load ramped to saturation)",
                        ["stage", "req/s asked", "req/s got", "out tok/s", "TTFT p50", "TTFT p95", "TPOT p50", "errors"], rows)
        else:
            print(f"\nTHROUGHPUT SWEEP - {label}: no results under s3://{args.bucket}/benchmarks/{label}/chat-throughput/")

        # 3. Cost/performance at the peak error-free stage
        peak_txt = f"{peak[1]:.0f} (stage {peak[0]})" if peak else "-"
        if peak and usd > 0:
            tokens_per_usd = peak[1] * 3600 / usd
            verdict_rows.append([label, peak_txt, f"{usd:.2f}", f"{tokens_per_usd:,.0f}", f"{1e6 / tokens_per_usd:.2f}"])
        else:
            verdict_rows.append([label, peak_txt, f"{usd:.2f}" if usd > 0 else "-", "-", "-"])

    print_table("LATENCY at 1 req/s  (ShareGPT, zero contention; client-side, ms)",
                ["target", "TTFT p50", "TTFT p95", "TPOT p50", "TPOT p95", "request p50"], latency_rows)
    print_table("COST / PERFORMANCE at peak throughput  (hourlyUsd from the Helm values, or --hourly-usd)",
                ["target", "peak out tok/s", "node $/hr", "out tokens per $", "$ per 1M out tokens"], verdict_rows)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
