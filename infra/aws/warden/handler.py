import os
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

    failed = []
    for region, ec2 in clients.items():
        ids = [instance_id for doomed_region, instance_id in doomed if doomed_region == region]
        if not ids:
            continue
        try:
            ec2.terminate_instances(InstanceIds=ids)
        except Exception as error:
            failed.append(f"{region} terminate {', '.join(ids)} ({error})")
    for region, ec2 in clients.items():
        failed.extend(_delete_orphan_volumes(ec2, region, now))
    if failed:
        raise RuntimeError(f"fleet sweep failed: {'; '.join(failed)}")
    return [instance_id for _, instance_id in doomed]


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
