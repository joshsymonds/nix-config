import sys
from datetime import datetime, timedelta, timezone

import pytest

import handler

NOW = datetime(2026, 10, 27, 12, 0, tzinfo=timezone.utc)


def box(
    instance_id,
    hours_old,
    *,
    cores=1,
    threads=2,
    state="running",
    fleet=True,
    max_hours=None,
):
    tags = []
    if fleet:
        tags.append({"Key": "fleet", "Value": "ec2"})
    if max_hours is not None:
        tags.append({"Key": "fleet-max-hours", "Value": max_hours})
    return {
        "InstanceId": instance_id,
        "LaunchTime": NOW - timedelta(hours=hours_old),
        "State": {"Name": state},
        "CpuOptions": {"CoreCount": cores, "ThreadsPerCore": threads},
        "Tags": tags,
    }


class StubEC2:
    """Hand-written EC2 client. Applies the Filters it receives and pages results."""

    def __init__(self, instances, page_size=1000, volumes=None, failing_volumes=()):
        # Without an explicit volume list, every instance gets one compliant root volume.
        self._instances = instances
        if volumes is None:
            volumes = [
                in_use_volume(f"vol-root-{i['InstanceId']}", i["InstanceId"], size=64)
                for i in instances
            ]
        self._volumes = list(volumes)
        self._page_size = page_size
        self._failing_volumes = set(failing_volumes)
        self.describe_calls = []
        self.terminate_calls = []
        self.volume_describe_calls = []
        self.delete_calls = []

    def describe_instances(self, Filters=None, NextToken=None):
        self.describe_calls.append({"Filters": Filters, "NextToken": NextToken})
        matched = [i for i in self._instances if _matches(i, Filters or [])]
        start = int(NextToken) if NextToken else 0
        end = start + self._page_size
        response = {
            "Reservations": [{"Instances": [i]} for i in matched[start:end]],
        }
        if end < len(matched):
            response["NextToken"] = str(end)
        return response

    def terminate_instances(self, InstanceIds):
        self.terminate_calls.append({"InstanceIds": list(InstanceIds)})
        return {"TerminatingInstances": []}

    def describe_volumes(self, Filters=None, NextToken=None):
        self.volume_describe_calls.append({"Filters": Filters, "NextToken": NextToken})
        matched = [v for v in self._volumes if _matches_volume(v, Filters or [])]
        start = int(NextToken) if NextToken else 0
        end = start + self._page_size
        response = {"Volumes": matched[start:end]}
        if end < len(matched):
            response["NextToken"] = str(end)
        return response

    def delete_volume(self, VolumeId):
        self.delete_calls.append(VolumeId)
        if VolumeId in self._failing_volumes:
            raise RuntimeError(f"UnauthorizedOperation deleting {VolumeId}")


def volume(volume_id, minutes_old, *, state="available", fleet=True):
    tags = [{"Key": "fleet", "Value": "ec2"}] if fleet else []
    return {
        "VolumeId": volume_id,
        "CreateTime": NOW - timedelta(minutes=minutes_old),
        "State": state,
        "Tags": tags,
        "Attachments": [],
    }


def in_use_volume(
    volume_id,
    instance_id,
    *,
    volume_type="gp3",
    size=512,
    iops=3000,
    throughput=125,
    delete_on_termination=True,
):
    return {
        "VolumeId": volume_id,
        "CreateTime": NOW - timedelta(hours=1),
        "State": "in-use",
        "Tags": [{"Key": "fleet", "Value": "ec2"}],
        "Attachments": [{
            "InstanceId": instance_id,
            "DeleteOnTermination": delete_on_termination,
            "State": "attached",
            "Device": "/dev/xvda",
        }],
        "VolumeType": volume_type,
        "Size": size,
        "Iops": iops,
        "Throughput": throughput,
    }


def _matches_volume(volume, filters):
    tags = {t["Key"]: t["Value"] for t in volume["Tags"]}
    for f in filters:
        name, values = f["Name"], f["Values"]
        if name == "status":
            ok = volume["State"] in values
        elif name.startswith("tag:"):
            ok = tags.get(name[len("tag:"):]) in values
        else:
            raise ValueError(f"stub does not support volume filter {name!r}")
        if not ok:
            return False
    return True


def _matches(instance, filters):
    tags = {t["Key"]: t["Value"] for t in instance["Tags"]}
    for f in filters:
        name, values = f["Name"], f["Values"]
        if name == "instance-state-name":
            ok = instance["State"]["Name"] in values
        elif name.startswith("tag:"):
            ok = tags.get(name[len("tag:"):]) in values
        else:
            raise ValueError(f"stub does not support filter {name!r}")
        if not ok:
            return False
    return True


def terminated_ids(client):
    return [i for call in client.terminate_calls for i in call["InstanceIds"]]


def test_over_cap_terminates_newest_first_until_rest_fits():
    # 4 x 64 vCPU = 256. Newest two (1h, 2h) go: 256 -> 192 -> 128, which is at the cap.
    client = StubEC2([
        box("oldest", 4, cores=32),
        box("older", 3, cores=32),
        box("newer", 2, cores=32),
        box("newest", 1, cores=32),
    ])

    assert handler.sweep(client, NOW) == ["newest", "newer"]
    assert client.terminate_calls == [{"InstanceIds": ["newest", "newer"]}]


def test_default_max_hours_is_24_when_tag_absent():
    client = StubEC2([
        box("expired", 25),
        box("fresh", 23),
        box("on-boundary", 24),
    ])

    assert handler.sweep(client, NOW) == ["expired"]
    assert client.terminate_calls == [{"InstanceIds": ["expired"]}]


def test_fleet_max_hours_tag_overrides_default():
    client = StubEC2([
        box("short-expired", 3, max_hours="2"),
        box("short-fresh", 1, max_hours="2"),
        box("long-kept", 25, max_hours="48"),
    ])

    assert handler.sweep(client, NOW) == ["short-expired"]


def test_max_hours_tag_at_ceiling_is_honored():
    client = StubEC2([
        box("ceiling-kept", 47, max_hours="48"),
    ])

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


@pytest.mark.parametrize("raw", ["49", "5000000"])
def test_max_hours_tag_above_ceiling_falls_back_to_default(raw):
    client = StubEC2([
        box("expired", 25, max_hours=raw),
        box("fresh", 23, max_hours=raw),
    ])

    assert handler.sweep(client, NOW) == ["expired"]
    assert client.terminate_calls == [{"InstanceIds": ["expired"]}]


@pytest.mark.parametrize("raw", ["", "0", "-3", "abc", "1.5"])
def test_invalid_max_hours_tag_falls_back_to_default(raw):
    client = StubEC2([
        box("expired", 25, max_hours=raw),
        box("fresh", 23, max_hours=raw),
    ])

    assert handler.sweep(client, NOW) == ["expired"]


@pytest.mark.parametrize("raw", ["100000000", "99999999999999"])
def test_unrepresentable_max_hours_tag_falls_back_to_default(raw):
    # The poisoned box is 30h old and 8 vCPU. Its tag is above the 48h ceiling, so it
    # must be judged at the 24h default and expire. The three 64-vCPU boxes put the
    # fleet at 200 vCPU, so the newest of them is cut after the poisoned box.
    client = StubEC2([
        box("poisoned", 30, cores=4, threads=2, max_hours=raw),
        box("n1", 1, cores=32),
        box("n2", 2, cores=32),
        box("n3", 3, cores=32),
    ])

    assert handler.sweep(client, NOW) == ["poisoned", "n1"]
    assert client.terminate_calls == [{"InstanceIds": ["poisoned", "n1"]}]


def test_stopped_boxes_count_toward_vcpu_cap():
    # Running 64 (1h) plus two stopped 64s (2h, 3h). Only the stopped boxes would
    # fit under the cap if they were ignored, so the running box is what gets cut.
    client = StubEC2([
        box("stopped-old", 3, cores=32, state="stopped"),
        box("stopped-mid", 2, cores=32, state="stopped"),
        box("running-new", 1, cores=32),
    ])

    assert handler.sweep(client, NOW) == ["running-new"]


def test_non_fleet_and_terminated_boxes_are_ignored():
    client = StubEC2([
        box("kept-a", 2, cores=32),
        box("kept-b", 1, cores=32),
        box("untagged-huge", 1, cores=100, fleet=False),
        box("untagged-expired", 100, fleet=False),
        box("terminated-expired", 100, cores=32, state="terminated"),
    ])

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


def test_describe_filters_fleet_tag_and_live_states():
    client = StubEC2([])

    handler.sweep(client, NOW)

    assert client.describe_calls == [{
        "Filters": [
            {"Name": "tag:fleet", "Values": ["ec2"]},
            {
                "Name": "instance-state-name",
                "Values": [
                    "pending",
                    "running",
                    "shutting-down",
                    "stopping",
                    "stopped",
                ],
            },
        ],
        "NextToken": None,
    }]


def test_pagination_visits_every_page():
    client = StubEC2(
        [
            box("fresh-1", 1),
            box("fresh-2", 2),
            box("fresh-3", 3),
            box("fresh-4", 4),
            box("expired-last-page", 30),
        ],
        page_size=2,
    )

    assert handler.sweep(client, NOW) == ["expired-last-page"]
    assert [c["NextToken"] for c in client.describe_calls] == [None, "2", "4"]


def test_no_op_at_cap_boundary_makes_no_terminate_call():
    client = StubEC2([
        box("a", 2, cores=32),
        box("b", 1, cores=32),
    ])

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


def test_no_instances_makes_no_terminate_call():
    client = StubEC2([])

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


def test_vcpu_is_core_count_times_threads_per_core():
    # Four boxes of 16 cores x 2 threads = 128 vCPU, exactly the cap.
    # The newest 1-core, 1-thread box pushes the rest over and is the one cut.
    client = StubEC2([
        box("a", 5, cores=16, threads=2),
        box("b", 4, cores=16, threads=2),
        box("c", 3, cores=16, threads=2),
        box("d", 2, cores=16, threads=2),
        box("tiny-newest", 0.5, cores=1, threads=1),
    ])

    assert handler.sweep(client, NOW) == ["tiny-newest"]


def test_handler_builds_ec2_client_and_returns_terminated_ids(monkeypatch):
    # handler() reads the real clock, so fixtures are placed relative to it.
    real_now = datetime.now(timezone.utc)
    client = StubEC2([
        {**box("expired", 0), "LaunchTime": real_now - timedelta(hours=100)},
        {**box("fresh", 0), "LaunchTime": real_now - timedelta(hours=1)},
    ])

    class FakeBoto3:
        requested = []

        @classmethod
        def client(cls, service):
            cls.requested.append(service)
            return client

    monkeypatch.setitem(sys.modules, "boto3", FakeBoto3)

    assert handler.handler({}, None) == ["expired"]
    assert FakeBoto3.requested == ["ec2"]
    assert client.terminate_calls == [{"InstanceIds": ["expired"]}]


def test_available_fleet_volume_older_than_15_minutes_is_deleted():
    client = StubEC2([], volumes=[
        volume("vol-orphan", 20),
        volume("vol-young", 5),
        volume("vol-in-use", 60, state="in-use"),
        volume("vol-untagged", 60, fleet=False),
    ])

    assert handler.sweep(client, NOW) == []
    assert client.delete_calls == ["vol-orphan"]


def test_volume_describe_filters_fleet_tag_and_available_status_across_pages():
    client = StubEC2(
        [],
        volumes=[volume(f"vol-{n}", 30) for n in range(5)],
        page_size=2,
    )

    handler.sweep(client, NOW)

    available_calls = [
        c for c in client.volume_describe_calls
        if {"Name": "status", "Values": ["available"]} in c["Filters"]
    ]
    assert [c["Filters"] for c in available_calls] == [
        [
            {"Name": "tag:fleet", "Values": ["ec2"]},
            {"Name": "status", "Values": ["available"]},
        ],
    ] * 3
    assert [c["NextToken"] for c in available_calls] == [None, "2", "4"]
    assert client.delete_calls == [f"vol-{n}" for n in range(5)]


def test_orphan_deletes_run_after_terminations_and_survive_one_failure():
    client = StubEC2(
        [box("expired", 25)],
        volumes=[volume("vol-bad", 30), volume("vol-good", 30)],
        failing_volumes=["vol-bad"],
    )

    with pytest.raises(RuntimeError, match="vol-bad"):
        handler.sweep(client, NOW)

    assert client.terminate_calls == [{"InstanceIds": ["expired"]}]
    assert client.delete_calls == ["vol-bad", "vol-good"]


def test_compliant_volume_at_every_limit_is_kept():
    client = StubEC2(
        [box("ok", 1, cores=32)],
        volumes=[in_use_volume("vol-ok", "ok", size=512, iops=3000, throughput=125)],
    )

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


@pytest.mark.parametrize("override", [
    {"volume_type": "io2"},
    {"size": 513},
    {"iops": 3001},
    {"throughput": 126},
    {"delete_on_termination": False},
])
def test_volume_off_launcher_shape_terminates_box(override):
    client = StubEC2(
        [box("bad", 1, cores=32)],
        volumes=[in_use_volume("vol-bad", "bad", **override)],
    )

    assert handler.sweep(client, NOW) == ["bad"]
    assert client.terminate_calls == [{"InstanceIds": ["bad"]}]


def test_box_with_two_fleet_volumes_terminates():
    client = StubEC2(
        [box("bad", 1, cores=32)],
        volumes=[
            in_use_volume("vol-root", "bad"),
            in_use_volume("vol-extra", "bad"),
        ],
    )

    assert handler.sweep(client, NOW) == ["bad"]
    assert client.terminate_calls == [{"InstanceIds": ["bad"]}]


def test_box_whose_root_volume_is_not_attached_yet_is_kept():
    client = StubEC2([box("launching", 0, cores=32, state="pending")], volumes=[])

    assert handler.sweep(client, NOW) == []
    assert client.terminate_calls == []


def test_shape_violator_does_not_count_toward_vcpu_cap():
    # The oldest box is the violator, 64 vCPU. If it counted, the 192 vCPU fleet would
    # cut the newer compliant box. Excluded, only the violator goes and 128 vCPU remain.
    client = StubEC2(
        [
            box("violator", 3, cores=32),
            box("compliant-old", 2, cores=32),
            box("compliant-new", 1, cores=32),
        ],
        volumes=[
            in_use_volume("vol-violator", "violator", volume_type="io2"),
            in_use_volume("vol-old", "compliant-old"),
            in_use_volume("vol-new", "compliant-new"),
        ],
    )

    assert handler.sweep(client, NOW) == ["violator"]
    assert client.terminate_calls == [{"InstanceIds": ["violator"]}]


def test_expired_and_violator_are_terminated_in_one_call():
    client = StubEC2(
        [box("expired", 25), box("bad", 1, cores=32)],
        volumes=[
            in_use_volume("vol-expired", "expired"),
            in_use_volume("vol-bad", "bad", iops=3001),
        ],
    )

    assert handler.sweep(client, NOW) == ["expired", "bad"]
    assert client.terminate_calls == [{"InstanceIds": ["expired", "bad"]}]


def test_in_use_volume_describe_filters_fleet_tag_and_in_use_status_across_pages():
    client = StubEC2([box(f"i{n}", 1, cores=1, threads=1) for n in range(5)], page_size=2)

    assert handler.sweep(client, NOW) == []

    in_use_calls = [
        c for c in client.volume_describe_calls
        if {"Name": "status", "Values": ["in-use"]} in c["Filters"]
    ]
    assert [c["Filters"] for c in in_use_calls] == [
        [
            {"Name": "tag:fleet", "Values": ["ec2"]},
            {"Name": "status", "Values": ["in-use"]},
        ],
    ] * 3
    assert [c["NextToken"] for c in in_use_calls] == [None, "2", "4"]
