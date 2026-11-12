import os
import re
from datetime import datetime, timedelta, timezone

CAP_VCPU = 128
DEFAULT_MAX_HOURS = 24
MAX_HOURS_CEILING = 48
LIVE_STATES = ["pending", "running", "shutting-down", "stopping", "stopped"]
FLEET_FILTERS = [
    {"Name": "tag:fleet", "Values": ["ec2"]},
    {"Name": "instance-state-name", "Values": LIVE_STATES},
]
ORPHAN_AGE = timedelta(minutes=15)
VOLUME_FILTERS = [
    {"Name": "tag:fleet", "Values": ["ec2"]},
    {"Name": "status", "Values": ["available"]},
]
IN_USE_VOLUME_FILTERS = [
    {"Name": "tag:fleet", "Values": ["ec2"]},
    {"Name": "status", "Values": ["in-use"]},
]
MAX_VOLUME_GIB = 512
MAX_IOPS = 3000
MAX_THROUGHPUT = 125
HEARTBEAT_AGE_SECONDS = 15 * 60
# An epoch of up to 15 digits; a longer number is no clock.
HEARTBEAT_LINE = re.compile(r"ec2-fleet-heartbeat ([0-9]{1,15})")


def handler(event, context):
    import boto3

    clients = {
        region: boto3.client("ec2", region_name=region) for region in _fleet_regions()
    }
    return sweep(clients, datetime.now(timezone.utc))


def _fleet_regions() -> list[str]:
    regions = [r.strip() for r in os.environ.get("FLEET_REGIONS", "").split(",") if r.strip()]
    if not regions:
        raise RuntimeError("FLEET_REGIONS must name at least one region")
    return regions


def sweep(clients: dict, now: datetime) -> list[str]:
    # Per region, instances are read before volumes: a box launched between the two reads
    # is then never judged against a volume list older than the box itself.
    fleet = []
    attached = {}
    for region, ec2 in clients.items():
        fleet.extend((region, instance) for instance in _fleet_instances(ec2))
        attached.update(_attachments_by_instance(_in_use_fleet_volumes(ec2)))

    doomed = []
    live = []
    for region, instance in fleet:
        if _deadline(instance) < now or _off_shape(attached.get(instance["InstanceId"], [])):
            doomed.append((region, instance["InstanceId"]))
        else:
            live.append((region, instance))

    remaining_vcpu = sum(_vcpus(instance) for _, instance in live)
    for region, instance in sorted(live, key=lambda r: r[1]["LaunchTime"], reverse=True):
        if remaining_vcpu <= CAP_VCPU:
            break
        doomed.append((region, instance["InstanceId"]))
        remaining_vcpu -= _vcpus(instance)

    doomed_ids = {instance_id for _, instance_id in doomed}
    survivors = [
        (region, instance) for region, instance in live if instance["InstanceId"] not in doomed_ids
    ]

    failed = []
    for region, ec2 in clients.items():
        ids = [instance_id for doomed_region, instance_id in doomed if doomed_region == region]
        if not ids:
            continue
        failed.extend(_terminate(ec2, region, ids))
    for region, ec2 in clients.items():
        failed.extend(_delete_orphan_volumes(ec2, region, now))
    # Heartbeats are read only after the rules above have issued their calls.
    stale = []
    for region, ec2 in clients.items():
        ids = [
            instance["InstanceId"]
            for survivor_region, instance in survivors
            if survivor_region == region and _heartbeat_lost(ec2, instance, now)
        ]
        if not ids:
            continue
        stale.extend(ids)
        failed.extend(_terminate(ec2, region, ids))
    if failed:
        raise RuntimeError(f"fleet sweep failed: {'; '.join(failed)}")
    return [instance_id for _, instance_id in doomed] + stale


def _terminate(ec2, region: str, ids: list[str]) -> list[str]:
    try:
        ec2.terminate_instances(InstanceIds=ids)
    except Exception as error:
        return [f"{region} terminate {', '.join(ids)} ({error})"]
    return []


def _heartbeat_lost(ec2, instance, now: datetime) -> bool:
    if instance["State"]["Name"] != "running":
        return False
    try:
        response = ec2.get_console_output(InstanceId=instance["InstanceId"], Latest=True)
    except Exception:
        # A failed read spares the box; the sweep carries on.
        return False
    launch = instance["LaunchTime"].timestamp()
    now_epoch = now.timestamp()
    if now_epoch - launch < HEARTBEAT_AGE_SECONDS:
        return False
    newest = _newest_heartbeat(response.get("Output", ""), launch)
    return newest is not None and now_epoch - newest > HEARTBEAT_AGE_SECONDS


def _newest_heartbeat(output: str, launch: float) -> int | None:
    # Only a line ended by a newline is complete; a final line cut off mid-write is skipped.
    epochs = []
    for line in output.split("\n")[:-1]:
        match = HEARTBEAT_LINE.fullmatch(line.removesuffix("\r"))
        if match is None:
            continue
        epoch = int(match.group(1))
        # A heartbeat dated before the box launched is a bad clock, not a heartbeat.
        if epoch >= launch:
            epochs.append(epoch)
    return max(epochs, default=None)


def _delete_orphan_volumes(ec2, region: str, now: datetime) -> list[str]:
    cutoff = now - ORPHAN_AGE
    failed = []
    for volume in _fleet_volumes(ec2):
        if volume["CreateTime"] >= cutoff:
            continue
        try:
            ec2.delete_volume(VolumeId=volume["VolumeId"])
        except Exception as error:
            # Another warden may have deleted this volume first; a gone volume is deleted.
            error_code = getattr(error, "response", {}).get("Error", {}).get("Code")
            if error_code == "InvalidVolume.NotFound":
                continue
            failed.append(f"{region} delete {volume['VolumeId']} ({error})")
    return failed


def _fleet_volumes(ec2) -> list[dict]:
    found = []
    request = {"Filters": VOLUME_FILTERS}
    while True:
        page = ec2.describe_volumes(**request)
        found.extend(page["Volumes"])
        token = page.get("NextToken")
        if not token:
            return found
        request = {"Filters": VOLUME_FILTERS, "NextToken": token}


def _in_use_fleet_volumes(ec2) -> list[dict]:
    found = []
    request = {"Filters": IN_USE_VOLUME_FILTERS}
    while True:
        page = ec2.describe_volumes(**request)
        found.extend(page["Volumes"])
        token = page.get("NextToken")
        if not token:
            return found
        request = {"Filters": IN_USE_VOLUME_FILTERS, "NextToken": token}


def _attachments_by_instance(volumes) -> dict[str, list[tuple[dict, dict]]]:
    by_instance = {}
    for volume in volumes:
        for attachment in volume["Attachments"]:
            by_instance.setdefault(attachment["InstanceId"], []).append((volume, attachment))
    return by_instance


def _off_shape(attachments) -> bool:
    # A pending box's root volume may not be attached yet, so no volume is not a violation.
    if not attachments:
        return False
    if len(attachments) > 1:
        return True
    volume, attachment = attachments[0]
    return (
        volume["VolumeType"] != "gp3"
        or volume["Size"] > MAX_VOLUME_GIB
        or volume["Iops"] > MAX_IOPS
        or volume["Throughput"] > MAX_THROUGHPUT
        or not attachment["DeleteOnTermination"]
    )


def _fleet_instances(ec2) -> list[dict]:
    found = []
    request = {"Filters": FLEET_FILTERS}
    while True:
        page = ec2.describe_instances(**request)
        for reservation in page["Reservations"]:
            found.extend(reservation["Instances"])
        token = page.get("NextToken")
        if not token:
            return found
        request = {"Filters": FLEET_FILTERS, "NextToken": token}


def _deadline(instance) -> datetime:
    return instance["LaunchTime"] + timedelta(hours=_max_hours(instance))


def _max_hours(instance) -> int:
    for tag in instance.get("Tags", []):
        if tag["Key"] == "fleet-max-hours":
            try:
                hours = int(tag["Value"])
            except ValueError:
                return DEFAULT_MAX_HOURS
            return hours if 0 < hours <= MAX_HOURS_CEILING else DEFAULT_MAX_HOURS
    return DEFAULT_MAX_HOURS


def _vcpus(instance) -> int:
    options = instance["CpuOptions"]
    return options["CoreCount"] * options["ThreadsPerCore"]
