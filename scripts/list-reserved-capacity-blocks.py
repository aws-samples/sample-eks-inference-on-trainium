#!/usr/bin/env python3
r"""List the EC2 Capacity Blocks you own, across regions.

Read-only: calls `aws ec2 describe-capacity-reservations` with
reservation-type=capacity-block in each region, and prints one table sorted by
start date. By default it shows blocks that are usable now or soon
(active, scheduled, payment-pending); --all adds expired, cancelled and failed.

Usage:
  scripts/capacity-blocks.py [--regions us-east-2 us-west-2] [--all] [-v]

The ID, instance type and AZ go into capacity_blocks_nodepools in
terraform/terraform.tfvars. Requires the AWS CLI v2 with credentials
(ec2:DescribeCapacityReservations).
"""
import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

# Enabled regions with Capacity Blocks (same list as capacity-block-offerings.py).
DEFAULT_REGIONS = [
    "ap-northeast-1", "ap-northeast-2", "ap-south-1", "ap-southeast-2", "ap-southeast-4",
    "eu-north-1", "eu-west-2", "eu-west-3", "sa-east-1",
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
]
CURRENT_STATES = ["active", "scheduled", "payment-pending"]


def query(region: str, states: list[str] | None) -> dict:
    filters = ["Name=reservation-type,Values=capacity-block"]
    if states:
        filters.append(f"Name=state,Values={','.join(states)}")
    cmd = ["aws", "ec2", "describe-capacity-reservations", "--region", region, "--filters", *filters, "--output", "json"]
    q = {"region": region, "cmd": " ".join(cmd), "rows": [], "detail": ""}
    # argv list, no shell: the arguments can't inject a command.
    res = subprocess.run(cmd, capture_output=True, text=True)  # nosemgrep
    if res.returncode != 0:
        q["detail"] = (res.stderr.strip().splitlines() or ["unknown error"])[-1].removeprefix("aws: [ERROR]: ")
        q["status"] = "unsupported" if "InvalidAction" in q["detail"] else "error"
        return q
    q["rows"] = [dict(r, Region=region) for r in json.loads(res.stdout).get("CapacityReservations", [])]
    q["status"] = "ok" if q["rows"] else "none"
    return q


def remaining(start: str, end: str, state: str) -> str:
    now = datetime.now(timezone.utc)
    s, e = datetime.fromisoformat(start), datetime.fromisoformat(end)
    if state == "active":
        h = (e - now).total_seconds() / 3600
        return f"{h:.0f}h left" if h >= 1 else f"{h * 60:.0f}m left"
    if state in ("scheduled", "payment-pending"):
        h = (s - now).total_seconds() / 3600
        return f"starts in {h:.0f}h" if h < 48 else f"starts in {h / 24:.0f}d"
    return ""


def print_table(header: list[str], rows: list[list[str]], right: set[int] = frozenset(), out=sys.stdout) -> None:
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header))]
    fmt = lambda r: "  ".join(c.rjust(w) if i in right else c.ljust(w) for i, (c, w) in enumerate(zip(r, widths)))
    print(fmt(header), file=out)
    print("  ".join("-" * w for w in widths), file=out)
    for r in rows:
        print(fmt(r), file=out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--regions", nargs="+", default=DEFAULT_REGIONS, metavar="REGION",
                    help="default: DEFAULT_REGIONS (Capacity Blocks-enabled regions)")
    ap.add_argument("--all", action="store_true", help="also show expired, cancelled and failed blocks")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="also print every query: region, status, blocks found, error and the aws command")
    args = ap.parse_args()

    states = None if args.all else CURRENT_STATES
    with ThreadPoolExecutor(max_workers=8) as pool:
        queries = list(pool.map(lambda r: query(r, states), args.regions))

    if args.verbose:
        print(f"States: {', '.join(states) if states else 'all'}\n", file=sys.stderr)
        print_table(["Region", "Status", "Blocks", "Detail"],
                    [[q["region"], q["status"], str(len(q["rows"])), q["detail"]] for q in queries], right={2}, out=sys.stderr)
        print("\nCommands:", file=sys.stderr)
        for q in queries:
            print(f"  {q['cmd']}", file=sys.stderr)
        print(file=sys.stderr)
        sys.stderr.flush()

    rows = [r for q in queries for r in q["rows"]]
    if not rows:
        print("No Capacity Blocks found." + ("" if args.all else " (use --all to include expired ones)"))
        return 1

    table = []
    for r in sorted(rows, key=lambda r: r["StartDate"]):
        total, avail = r["TotalInstanceCount"], r["AvailableInstanceCount"]
        table.append([
            r["CapacityReservationId"], r["Region"], r["AvailabilityZone"], r["InstanceType"], r["State"],
            f"{total - avail}/{total}", r["StartDate"][:16].replace("T", " "), r["EndDate"][:16].replace("T", " "),
            remaining(r["StartDate"], r["EndDate"], r["State"]),
        ])
    print_table(["Reservation ID", "Region", "AZ", "Instance type", "State", "In use", "Start (UTC)", "End (UTC)", "Time"],
                table, right={5})
    return 0


if __name__ == "__main__":
    sys.exit(main())
