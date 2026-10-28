from datetime import datetime, timedelta, timezone

CAP_VCPU = 128
DEFAULT_MAX_HOURS = 24
MAX_HOURS_CEILING = 48
LIVE_STATES = ["pending", "running", "shutting-down", "stopping", "stopped"]
FLEET_FILTERS = [
    {"Name": "tag:fleet", "Values": ["ec2"]},
    {"Name": "instance-state-name", "Values": LIVE_STATES},
]


def handler(event, context):
    import boto3

    ec2 = boto3.client("ec2")
    return sweep(ec2, datetime.now(timezone.utc))


def sweep(ec2, now: datetime) -> list[str]:
    expired = []
    live = []
    for instance in _fleet_instances(ec2):
        if _deadline(instance) < now:
            expired.append(instance)
        else:
            live.append(instance)

    doomed = [i["InstanceId"] for i in expired]
    remaining_vcpu = sum(_vcpus(i) for i in live)
    for instance in sorted(live, key=lambda i: i["LaunchTime"], reverse=True):
        if remaining_vcpu <= CAP_VCPU:
            break
        doomed.append(instance["InstanceId"])
        remaining_vcpu -= _vcpus(instance)

    if doomed:
        ec2.terminate_instances(InstanceIds=doomed)
    return doomed


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
