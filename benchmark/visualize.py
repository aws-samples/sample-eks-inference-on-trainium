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


# Region for all S3 calls. Set from the bucket's actual location so cp/HeadObject
# don't fail with "301 Moved Permanently" when the CLI default region differs.
_REGION: str | None = None


def _aws(*args: str) -> str:
    cmd = ["aws", *args]
    if _REGION:
        cmd += ["--region", _REGION]
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def resolve_region(bucket: str) -> str:
    """Return the bucket's region (us-east-1 reports empty LocationConstraint)."""
    out = _aws(
        "s3api", "get-bucket-location", "--bucket", bucket,
        "--query", "LocationConstraint", "--output", "text",
    ).strip()
    return "us-east-1" if out in ("", "None", "null") else out


def latest_summary(bucket: str, label: str, test: str) -> dict | None:
    """Return the parsed summary_lifecycle_metrics.json for the most recent run,
    or None if there are no runs for this label/test under the bucket."""
    prefix = f"benchmarks/{label}/{test}/"
    try:
        listing = _aws("s3", "ls", f"s3://{bucket}/{prefix}", "--recursive")
    except subprocess.CalledProcessError:
        return None
    # `aws s3 ls --recursive` lines are: <date> <time> <size> <key>. Pick the
    # summary file with the latest (date, time) so the newest run wins regardless
    # of its random folder suffix.
    runs = []
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[-1].endswith("summary_lifecycle_metrics.json"):
            runs.append((parts[0] + " " + parts[1], parts[-1]))
    if not runs:
        return None
    runs.sort()
    body = _aws("s3", "cp", f"s3://{bucket}/{runs[-1][1]}", "-")
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

    if not args.bucket or not args.label:
        ap.error(
            "--bucket and --label must be non-empty "
            f"(got bucket={args.bucket!r}, label={args.label!r}); "
            "check that $S3_BUCKET_NAME and $TARGET_LABEL are exported."
        )

    global _REGION
    _REGION = resolve_region(args.bucket)

    print(f"\n=== Benchmark results: {args.label} ===\n")

    lat = latest_summary(args.bucket, args.label, "chat-latency")
    if lat:
        s = lat["successes"]
        ttft = s["latency"]["time_to_first_token"]
        itl = s["latency"]["time_per_output_token"]
        print("CHAT-LATENCY  (ShareGPT, 1 req/s, zero contention)")
        print(f"  TTFT  p50 {ttft['median']*1000:8.1f} ms   p95 {ttft['p95']*1000:8.1f} ms")
        print(f"  ITL   p50 {itl['median']*1000:8.2f} ms   p95 {itl['p95']*1000:8.2f} ms\n")
    else:
        print(f"CHAT-LATENCY  no results at s3://{args.bucket}/benchmarks/{args.label}/chat-latency/\n")

    thr = latest_summary(args.bucket, args.label, "chat-throughput")
    if thr:
        s = thr["successes"]
        tps = s["throughput"]["output_tokens_per_sec"]
        ttft = s["latency"]["time_to_first_token"]
        print("CHAT-THROUGHPUT  (ShareGPT, sustained peak)")
        print(f"  Output tokens/sec {tps:10.1f}   TTFT p95 {ttft['p95']*1000:8.1f} ms\n")
        print("COST / PERFORMANCE")
        print(
            f"  {tps/args.hourly_usd:10.1f} output tokens per dollar"
            f"  (@ ${args.hourly_usd:.2f}/hr)\n"
        )
    else:
        print(f"CHAT-THROUGHPUT  no results at s3://{args.bucket}/benchmarks/{args.label}/chat-throughput/\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
