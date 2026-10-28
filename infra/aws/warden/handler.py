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

    ec2 = boto3.client("ec2")
    return sweep(ec2, datetime.now(timezone.utc))


def sweep(ec2, now: datetime) -> list[str]:
    # Instances are read before volumes: a box launched between the two reads is then
    # never judged against a volume list older than the box itself.
    instances = _fleet_instances(ec2)
    attached = _attachments_by_instance(_in_use_fleet_volumes(ec2))

    doomed = []
    live = []
    for instance in instances:
        if _deadline(instance) < now or _off_shape(attached.get(instance["InstanceId"], [])):
            doomed.append(instance["InstanceId"])
        else:
            live.append(instance)

    remaining_vcpu = sum(_vcpus(i) for i in live)
    for instance in sorted(live, key=lambda i: i["LaunchTime"], reverse=True):
        if remaining_vcpu <= CAP_VCPU:
            break
        doomed.append(instance["InstanceId"])
        remaining_vcpu -= _vcpus(instance)

    if doomed:
        ec2.terminate_instances(InstanceIds=doomed)
    _delete_orphan_volumes(ec2, now)
    return doomed


def _delete_orphan_volumes(ec2, now: datetime) -> None:
    cutoff = now - ORPHAN_AGE
    failed = []
    for volume in _fleet_volumes(ec2):
        if volume["CreateTime"] >= cutoff:
            continue
        try:
            ec2.delete_volume(VolumeId=volume["VolumeId"])
        except Exception as error:
            failed.append(f"{volume['VolumeId']} ({error})")
    if failed:
        raise RuntimeError(f"failed to delete orphaned fleet volumes: {', '.join(failed)}")


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
