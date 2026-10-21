#!/usr/bin/env python3
"""Purchase one or more EC2 Capacity Block offerings.

Each argument is <offering-id>,<region> (offering IDs are cb-..., from
scripts/list-capacity-block-offerings.py). Purchasing is a non-refundable charge for
the whole block, so the script:
  1. checks with a dry run per region that your credentials may purchase (EC2's
     dry run checks permissions only: an expired or unknown offering ID still
     passes, and only the real purchase rejects it),
  2. lists the offerings and asks you to type "yes" to confirm (skip with --yes),
  3. purchases them one by one (a failed purchase doesn't stop the rest) and
     prints each resulting Capacity Reservation (cr-...), with the
     capacity_blocks_nodepools entries for terraform/terraform.tfvars.

Usage:
  scripts/purchase-capacity-block.py <offering-id>,<region> [<offering-id>,<region> ...] \\
    [--instance-platform Linux/UNIX] [--yes]

  scripts/purchase-capacity-block.py cb-0c93a2008ba8502ad,ap-southeast-4 cb-0123456789abcdef0,us-east-2

Requires the AWS CLI v2 with credentials (ec2:PurchaseCapacityBlock).
"""
import argparse
import json
import subprocess
import sys


def aws(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["aws", *args], capture_output=True, text=True)


def offering(arg: str) -> tuple[str, str]:
    """Parse <offering-id>,<region>."""
    parts = [p.strip() for p in arg.split(",")]
    if len(parts) != 2 or not all(parts):
        raise argparse.ArgumentTypeError(f"{arg!r}: expected <offering-id>,<region>")
    oid, region = parts
    if not oid.startswith("cb-"):
        raise argparse.ArgumentTypeError(f"{oid!r} isn't an offering ID: offerings start with cb- "
                                         "(cr-... is the reservation a purchase creates)")
    return oid, region


def purchase_cmd(oid: str, region: str, platform: str) -> list[str]:
    return ["ec2", "purchase-capacity-block", "--region", region, "--capacity-block-offering-id", oid,
            "--instance-platform", platform, "--output", "json"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("offerings", nargs="+", type=offering, metavar="OFFERING_ID,REGION")
    ap.add_argument("--instance-platform", default="Linux/UNIX", help="default: Linux/UNIX")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    args = ap.parse_args()
    offerings = list(dict.fromkeys(args.offerings))  # drop duplicates, keep order

    # 1. Dry run, once per region: EC2 answers DryRunOperation when the caller may purchase.
    for region in dict.fromkeys(r for _, r in offerings):
        oid = next(o for o, r in offerings if r == region)
        dry = aws(*purchase_cmd(oid, region, args.instance_platform), "--dry-run")
        if "DryRunOperation" not in dry.stderr:
            print(f"Dry run failed in {region}, nothing purchased:\n{dry.stderr.strip() or dry.stdout.strip()}",
                  file=sys.stderr)
            return 1
    print("Dry run OK: allowed to purchase in " + ", ".join(dict.fromkeys(r for _, r in offerings))
          + " (the offerings themselves are only checked by the purchase).")

    # 2. Confirm.
    print(f"\nAbout to purchase {len(offerings)} Capacity Block(s), each charged its full price (non-refundable):")
    for oid, region in offerings:
        print(f"  {oid}  {region}")
    if not args.yes:
        try:
            answer = input('Type "yes" to purchase: ').strip()
        except EOFError:
            answer = ""
        if answer != "yes":
            print("Not confirmed, nothing purchased.")
            return 1

    # 3. Purchase each; keep going on failure.
    bought, failed = [], []
    for oid, region in offerings:
        res = aws(*purchase_cmd(oid, region, args.instance_platform))
        if res.returncode != 0:
            failed.append((oid, region, res.stderr.strip()))
            print(f"\n{oid} ({region}): purchase FAILED\n  {res.stderr.strip()}", file=sys.stderr)
            continue
        cr = json.loads(res.stdout)["CapacityReservation"]
        bought.append(cr)
        print(f"\n{oid} ({region}): purchased")
        for k in ("CapacityReservationId", "InstanceType", "AvailabilityZone", "TotalInstanceCount",
                  "StartDate", "EndDate", "State"):
            print(f"  {k:22s} {cr.get(k)}")

    if bought:
        print("\nterraform/terraform.tfvars, capacity_blocks_nodepools (name each key after its values file;"
              " one cluster serves one region):")
        for cr in bought:
            hw = "neuron" if cr["InstanceType"].startswith(("trn", "inf")) else "gpu"
            print(f'''  "<pool-name>" = {{
    reservation_id = "{cr['CapacityReservationId']}"
    instance_type  = "{cr['InstanceType']}"
    az             = "{cr['AvailabilityZone']}"
    node_count     = {cr['TotalInstanceCount']}
    hardware       = "{hw}"
  }}''')
    print(f"\n{len(bought)} purchased, {len(failed)} failed.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
