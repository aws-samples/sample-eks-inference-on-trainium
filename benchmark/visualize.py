#!/usr/bin/env python3
r"""Summarize inference-perf benchmark results from S3, endpoints side by side.

For each target label it reads the latest run under s3://<bucket>/benchmarks/<label>/:
  <test>/<run>/target.json     URL + cost basis (hourlyUsd from the Helm values)
  <test>/<run>/serving.json    the endpoint's serving config when it was benchmarked
  chat-latency/<run>/summary_lifecycle_metrics.json
  chat-throughput/<run>/stage_<n>_lifecycle_metrics.json

and prints:
  0. Serving config per target, flagging settings that differ between targets
  1. Latency at the chat-latency load: TTFT, TPOT and request latency (client-side, p50/p95)
  2. Throughput stages: per load stage, achieved rate, output tokens/s, TTFT and
     TPOT - where latency bends is where the endpoint saturates
  3. Cost/performance before saturation: output tokens/s at the highest load
     stage still within the latency target (error-free, achieved rate keeping
     up with requested, TTFT p95 <= --ttft-p95-ms), as tokens per $ and $ per
     1M output tokens. Stages past that point are excluded: their throughput
     comes with a growing queue no user would accept.

Usage:
  benchmark/visualize.py --bucket "$S3_BUCKET_NAME" \
      --targets gpt-oss-20b-trn2-48xl gpt-oss-20b-p5-48xl \
      [--hourly-usd gpt-oss-20b-trn2-48xl=<usd/hr> ...] \   # overrides target.json
      [--ttft-p95-ms 1000]                                    # latency target

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


def serving_row(label: str, serving: dict) -> tuple[list[str], dict]:
    """Table row + the comparable settings of one target's serving.json."""
    if not serving or serving.get("available") is False:
        return [label, "config unknown (not a vllm-serving endpoint)"] + [""] * 7, {}
    v = serving.get("vllm", {})
    extra = " ".join(a.split("=")[0] for a in v.get("extraArgs", []))
    row = [
        label, serving.get("image", "").rsplit("/", 1)[-1], serving.get("nodepool", ""),
        f"{serving.get('replicas')} x TP{v.get('tensorParallelSize')}",
        str(serving.get("resources", {}).get("devices", "")), str(v.get("maxModelLen", "")),
        str(v.get("maxNumSeqs", "")), str(v.get("maxNumBatchedTokens", "")), extra,
    ]
    held = {"model": serving.get("model"), "max_model_len": v.get("maxModelLen"), "max_num_seqs": v.get("maxNumSeqs"),
            "common flags": tuple(v.get("commonArgs", []))}
    return row, held


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bucket", required=True, help="S3 results bucket name")
    ap.add_argument("--targets", nargs="+", required=True, metavar="LABEL", help="benchmark target labels")
    ap.add_argument("--hourly-usd", nargs="*", default=[], metavar="LABEL=USD",
                    help="override a target's $/hr (default: hourlyUsd from its target.json)")
    ap.add_argument("--ttft-p95-ms", type=float, default=1000,
                    help="latency target for cost/performance: a stage counts if its TTFT p95 is at or "
                         "below this (default: 1000 ms), it has no errors and achieved >= 90%% of requested req/s")
    args = ap.parse_args()
    if not args.bucket:
        ap.error("--bucket is empty; check that $S3_BUCKET_NAME is exported.")
    overrides = dict(o.split("=", 1) for o in args.hourly_usd)

    global _REGION
    _REGION = resolve_region(args.bucket)

    serving_rows, held_by_target, latency_rows, verdict_rows, stage_tables = [], {}, [], [], []
    for label in args.targets:
        lat = latest_run(args.bucket, label, "chat-latency")
        thr = latest_run(args.bucket, label, "chat-throughput")
        run = thr or lat
        # Context stored with the run (older runs: target.json at the label root).
        target = (s3_json(args.bucket, run["target.json"]) if "target.json" in run else None) \
            or s3_json(args.bucket, f"benchmarks/{label}/target.json") or {}
        serving = s3_json(args.bucket, run["serving.json"]) if "serving.json" in run else {}
        row, held = serving_row(label, serving or {})
        serving_rows.append(row)
        if held:
            held_by_target[label] = held
        usd = float(overrides.get(label, target.get("hourlyUsd") or 0))

        # 1. Latency at 1 req/s
        s = (s3_json(args.bucket, lat["summary_lifecycle_metrics.json"]) or {}).get("successes") if lat else None
        l = s["latency"] if s else {}
        latency_rows.append([
            label,
            ms(l.get("time_to_first_token"), "median"), ms(l.get("time_to_first_token"), "p95"),
            ms(l.get("time_per_output_token"), "median"), ms(l.get("time_per_output_token"), "p95"),
            ms(l.get("request_latency"), "median"),
        ])

        # 2. Throughput stages, stage by stage
        stages = sorted(
            (int(re.search(r"stage_(\d+)_", f).group(1)), s3_json(args.bucket, k))
            for f, k in thr.items() if re.match(r"stage_\d+_lifecycle_metrics\.json", f)
        )
        rows, peak, slo = [], None, args.ttft_p95_ms / 1000
        for n, st in stages:
            if not st:
                continue
            succ, load = st["successes"], st["load_summary"]
            tps = succ["throughput"]["output_tokens_per_sec"]
            fails = st.get("failures", {}).get("count", 0)
            ttft_p95 = (succ["latency"].get("time_to_first_token") or {}).get("p95", float("inf"))
            keeps_up = load.get("achieved_rate", 0) >= 0.9 * load.get("requested_rate", 0)
            within = fails == 0 and keeps_up and ttft_p95 <= slo
            rows.append([
                str(n), f"{load.get('requested_rate', 0):.2f}", f"{load.get('achieved_rate', 0):.2f}",
                f"{tps:.0f}", ms(succ["latency"].get("time_to_first_token"), "median"),
                ms(succ["latency"].get("time_to_first_token"), "p95"),
                ms(succ["latency"].get("time_per_output_token"), "median"), str(fails),
                "yes" if within else "no",
            ])
            if within and (peak is None or tps > peak[1]):
                peak = (n, tps)
        stage_tables.append((label, rows))

        # 3. Cost/performance at the highest stage within the latency target
        peak_txt = f"{peak[1]:.0f} (stage {peak[0]})" if peak else "-"
        if peak and usd > 0:
            tokens_per_usd = peak[1] * 3600 / usd
            verdict_rows.append([label, peak_txt, f"{usd:.2f}", f"{tokens_per_usd:,.0f}", f"{1e6 / tokens_per_usd:.2f}"])
        else:
            verdict_rows.append([label, peak_txt, f"{usd:.2f}" if usd > 0 else "-", "-", "-"])

    print_table("SERVING CONFIG  (from each run's serving.json)",
                ["target", "image", "node pool", "replicas", "devices/replica", "max_model_len", "max_num_seqs",
                 "max_num_batched_tokens", "extra flags"], serving_rows)
    differs = [k for k in ("model", "max_model_len", "max_num_seqs", "common flags")
               if len({repr(h.get(k)) for h in held_by_target.values()}) > 1]
    if len(held_by_target) > 1:
        print("  Held constant: " + ("all of model, max_model_len, max_num_seqs, common flags" if not differs
                                    else "NO - differs: " + ", ".join(differs)))

    for label, rows in stage_tables:
        if rows:
            print_table(f"THROUGHPUT STAGES - {label}  (ShareGPT, load stepped into saturation)",
                        ["stage", "req/s asked", "req/s got", "out tok/s", "TTFT p50", "TTFT p95", "TPOT p50", "errors",
                         "within target"], rows)
        else:
            print(f"\nTHROUGHPUT STAGES - {label}: no results under s3://{args.bucket}/benchmarks/{label}/chat-throughput/")

    print_table("LATENCY at the chat-latency load  (ShareGPT, far below saturation; client-side, ms)",
                ["target", "TTFT p50", "TTFT p95", "TPOT p50", "TPOT p95", "request p50"], latency_rows)
    print_table(f"COST / PERFORMANCE before saturation  (highest stage with TTFT p95 <= {args.ttft_p95_ms:.0f} ms, "
                "no errors, achieved >= 90% of requested; hourlyUsd from the Helm values, or --hourly-usd)",
                ["target", "out tok/s within target", "node $/hr", "out tokens per $", "$ per 1M out tokens"], verdict_rows)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
