#!/usr/bin/env python3
"""List EC2 Capacity Block offerings for instance types across regions.

Read-only: calls `aws ec2 describe-capacity-block-offerings` per (region,
instance type) and prints one table sorted by start date. Buy one with:
  aws ec2 purchase-capacity-block --region <region> \\
    --capacity-block-offering-id <id> --instance-platform Linux/UNIX

Usage:
  scripts/capacity-block-offerings.py \\
    [--instance-types trn2.48xlarge p5.48xlarge] \\
    [--regions us-east-2 us-west-2] \\
    [--count 1] [--hours 24] [--start 2026-10-20] [--end 2026-10-27] [-v]

--regions defaults to DEFAULT_REGIONS below: the account's enabled regions where
the Capacity Blocks API is available (checked 2026-10-13). Pairs whose instance
type isn't offered as a Capacity Block in a region are skipped; -v shows every
query (status, error, aws command).

Requires the AWS CLI v2 with credentials (ec2:DescribeCapacityBlockOfferings).
"""
import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# Enabled regions with the Capacity Blocks API (others return InvalidAction:
# ap-northeast-3, ap-southeast-1, ca-central-1, eu-central-1, eu-west-1).
# As of 2026-10-13: trn2.48xlarge is only offered in us-east-2; p5.48xlarge in
# ap-northeast-1, ap-south-1, ap-southeast-2, eu-north-1, eu-west-2, sa-east-1,
# us-east-1, us-east-2, us-west-1, us-west-2.
# All Trainium2 and P5 sizes (--instance-types overrides).
DEFAULT_INSTANCE_TYPES = [
    "trn2.3xlarge", "trn2.48xlarge", "trn2u.48xlarge",
    "p5.4xlarge", "p5.48xlarge", "p5e.48xlarge", "p5en.48xlarge",
]

DEFAULT_REGIONS = [
    "ap-northeast-1", "ap-northeast-2", "ap-south-1", "ap-southeast-2", "ap-southeast-4",
    "eu-north-1", "eu-west-2", "eu-west-3", "sa-east-1",
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
]


def query(region: str, instance_type: str, args) -> dict:
    """One describe call. status: ok | none | unsupported | error."""
    cmd = [
        "aws", "ec2", "describe-capacity-block-offerings",
        "--region", region,
        "--instance-type", instance_type,
        "--instance-count", str(args.count),
        "--capacity-duration-hours", str(args.hours),
        "--output", "json",
    ]
    if args.start:
        cmd += ["--start-date-range", f"{args.start}T00:00:00Z"]
    if args.end:
        cmd += ["--end-date-range", f"{args.end}T00:00:00Z"]
    q = {"region": region, "type": instance_type, "cmd": " ".join(cmd), "rows": [], "detail": ""}
    # argv list, no shell: the arguments can't inject a command.
    res = subprocess.run(cmd, capture_output=True, text=True)  # nosemgrep
    if res.returncode != 0:
        q["detail"] = (res.stderr.strip().splitlines() or ["unknown error"])[-1].removeprefix("aws: [ERROR]: ")
        q["status"] = "unsupported" if ("InvalidParameterValue" in q["detail"] or "InvalidAction" in q["detail"]) else "error"
        return q
    q["rows"] = [dict(o, Region=region) for o in json.loads(res.stdout).get("CapacityBlockOfferings", [])]
    q["status"] = "ok" if q["rows"] else "none"
    return q


def print_table(header: list[str], rows: list[list[str]], right: set[int] = frozenset(), out=sys.stdout) -> None:
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header))]
    fmt = lambda r: "  ".join(c.rjust(w) if i in right else c.ljust(w) for i, (c, w) in enumerate(zip(r, widths)))
    print(fmt(header), file=out)
    print("  ".join("-" * w for w in widths), file=out)
    for r in rows:
        print(fmt(r), file=out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--instance-types", nargs="+", default=DEFAULT_INSTANCE_TYPES, metavar="TYPE",
                    help="default: DEFAULT_INSTANCE_TYPES (all trn2 and p5 sizes)")
    ap.add_argument("--regions", nargs="+", default=DEFAULT_REGIONS, metavar="REGION",
                    help="default: DEFAULT_REGIONS (Capacity Blocks-enabled regions)")
    ap.add_argument("--count", type=int, default=1, help="instances per block (default 1)")
    ap.add_argument("--hours", type=int, default=24, help="block duration in hours, multiple of 24 (default 24)")
    ap.add_argument("--start", help="earliest start date, YYYY-MM-DD (default: now)")
    ap.add_argument("--end", help="latest end date, YYYY-MM-DD")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="also print every query: region, type, status, offerings, error and the aws command")
    args = ap.parse_args()

    pairs = [(r, t) for r in args.regions for t in args.instance_types]
    with ThreadPoolExecutor(max_workers=8) as pool:
        queries = list(pool.map(lambda p: query(*p, args), pairs))

    if args.verbose:
        print(f"Queries: {args.count} instance(s) x {args.hours}h, start {args.start or 'now'}, end {args.end or 'any'}\n", file=sys.stderr)
        print_table(
            ["Region", "Instance type", "Status", "Offerings", "Detail"],
            [[q["region"], q["type"], q["status"], str(len(q["rows"])), q["detail"]] for q in queries],
            right={3}, out=sys.stderr,
        )
        print("\nCommands:", file=sys.stderr)
        for q in queries:
            print(f"  {q['cmd']}", file=sys.stderr)
        print(file=sys.stderr)
        sys.stderr.flush()

    rows = [o for q in queries for o in q["rows"]]
    if not rows:
        print("No Capacity Block offerings found.")
        return 1

    table = []
    for o in sorted(rows, key=lambda o: (o["StartDate"], float(o["UpfrontFee"]))):
        fee, hours, cur = float(o["UpfrontFee"]), int(o["CapacityBlockDurationHours"]), o.get("CurrencyCode", "USD")
        table.append([
            o["CapacityBlockOfferingId"], o["Region"], o["AvailabilityZone"], o["InstanceType"],
            str(o["InstanceCount"]), o["StartDate"][:16].replace("T", " "), o["EndDate"][:16].replace("T", " "),
            str(hours), f"{fee:,.2f} {cur}", f"{fee / hours:,.2f} {cur}",
        ])
    print_table(
        ["Offering ID", "Region", "AZ", "Instance type", "Nodes", "Start (UTC)", "End (UTC)", "Hours", "Total", "Per hour"],
        table, right={4, 7, 8, 9},
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
