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

    def __init__(self, instances, page_size=1000):
        self._instances = instances
        self._page_size = page_size
        self.describe_calls = []
        self.terminate_calls = []

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
