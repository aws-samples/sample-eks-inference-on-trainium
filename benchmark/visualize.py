#!/usr/bin/env python3
"""Summarize inference-perf benchmark results from S3.

Reads the latest latency and throughput runs for a given target label and prints
the three answers the benchmark is designed to produce:

  - lowest p50/p95 latency (TTFT + ITL)
  - highest sustained output tokens/sec (throughput sweep peak)
  - best cost/performance (output tokens per dollar)

Usage:
  benchmark/visualize.py --bucket "$S3_BUCKET_NAME" --label "$TARGET_LABEL" \
      --hourly-usd "$NODE_HOURLY_USD"

Requires the AWS CLI on PATH with credentials that can read the bucket.
"""
import argparse
import json
import subprocess
import sys


def _aws(*args: str) -> str:
    return subprocess.run(
        ["aws", *args], capture_output=True, text=True, check=True
    ).stdout


def latest_summary(bucket: str, label: str, test: str) -> dict | None:
    """Return the parsed summary_lifecycle_metrics.json for the most recent run."""
    prefix = f"benchmarks/{label}/{test}/"
    try:
        listing = _aws("s3", "ls", f"s3://{bucket}/{prefix}", "--recursive")
    except subprocess.CalledProcessError:
        return None
    keys = sorted(
        line.split()[-1]
        for line in listing.splitlines()
        if line.strip().endswith("summary_lifecycle_metrics.json")
    )
    if not keys:
        return None
    body = _aws("s3", "cp", f"s3://{bucket}/{keys[-1]}", "-")
    return json.loads(body)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bucket", required=True, help="S3 results bucket name")
    ap.add_argument("--label", required=True, help="target label (e.g. vllm, ray)")
    ap.add_argument(
        "--hourly-usd",
        type=float,
        required=True,
        help="node on-demand $/hr for the cost/performance metric",
    )
    args = ap.parse_args()

    print(f"\n=== Benchmark results: {args.label} ===\n")

    lat = latest_summary(args.bucket, args.label, "latency")
    if lat:
        s = lat["successes"]
        ttft = s["latency"]["time_to_first_token"]
        itl = s["latency"]["time_per_output_token"]
        print("LATENCY  (1 req/s, zero contention)")
        print(f"  TTFT  p50 {ttft['median']*1000:8.1f} ms   p95 {ttft['p95']*1000:8.1f} ms")
        print(f"  ITL   p50 {itl['median']*1000:8.2f} ms   p95 {itl['p95']*1000:8.2f} ms\n")
    else:
        print("LATENCY  no results found\n")

    thr = latest_summary(args.bucket, args.label, "throughput")
    if thr:
        tps = thr["successes"]["throughput"]["output_tokens_per_sec"]
        print("THROUGHPUT  (synthetic sweep peak)")
        print(f"  Output tokens/sec {tps:10.1f}\n")
        print("COST / PERFORMANCE")
        print(
            f"  {tps/args.hourly_usd:10.1f} output tokens per dollar"
            f"  (@ ${args.hourly_usd:.2f}/hr)\n"
        )
    else:
        print("THROUGHPUT  no results found\n")

    chat = latest_summary(args.bucket, args.label, "chat")
    if chat:
        s = chat["successes"]
        tps = s["throughput"]["output_tokens_per_sec"]
        ttft = s["latency"]["time_to_first_token"]
        print("CHAT  (realistic ShareGPT workload, sweep peak)")
        print(f"  Output tokens/sec {tps:10.1f}   TTFT p95 {ttft['p95']*1000:8.1f} ms")
        print(f"  {tps/args.hourly_usd:10.1f} output tokens per dollar"
              f"  (@ ${args.hourly_usd:.2f}/hr)\n")
    else:
        print("CHAT  no results found\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
