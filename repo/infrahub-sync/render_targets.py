#!/usr/bin/env python3
"""
Render gNMIc Target manifests from Infrahub (the single source of truth).

Declarative: queries the full set of devices and rewrites the entire targets
file. Address and port now come from each device's gnmi_address / gnmi_port
attributes in Infrahub — nothing about connectivity is hardcoded here anymore.
Change a device's address in Infrahub and it flows through on the next sync.

Environment:
  INFRAHUB_ADDRESS, INFRAHUB_API_TOKEN
  OUTPUT_FILE   (default 02-targets.yaml)
"""
import os
import sys
import asyncio

from infrahub_sdk import InfrahubClient, Config

OUTPUT_FILE = os.environ.get("OUTPUT_FILE", "02-targets.yaml")
DEFAULT_GNMI_PORT = 57400

HEADER = """\
# ---------------------------------------------------------------------------
# GENERATED FILE — DO NOT EDIT BY HAND.
# Rendered from Infrahub by render_targets.py. Address/port come from each
# device's gnmi_address / gnmi_port in Infrahub. Infrahub is the source of truth.
# ---------------------------------------------------------------------------
apiVersion: operator.gnmic.dev/v1alpha1
kind: TargetProfile
metadata:
  name: default-profile
  namespace: default
spec:
  credentialsRef: device-credentials
  tls: {}
  timeout: 10s
  encoding: JSON_IETF
"""

TARGET_TMPL = """\
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Target
metadata:
  name: {name}
  namespace: default
  labels:
    role: {role}
spec:
  address: {address}:{port}
  profile: default-profile
"""

SUBSCRIPTIONS = """\
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Subscription
metadata:
  name: interface-stats
  namespace: default
  labels:
    type: interfaces
spec:
  paths:
    - /interface/statistics
    - /interface/oper-state
  mode: STREAM/SAMPLE
  sampleInterval: 5s
  encoding: JSON_IETF
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Subscription
metadata:
  name: system-stats
  namespace: default
  labels:
    type: system
spec:
  paths:
    - /platform/control[slot=A]/cpu[index=all]/total
  mode: STREAM/SAMPLE
  sampleInterval: 10s
  encoding: JSON_IETF
"""


def attr_value(node, attr, default=None):
    """Safely read an attribute .value that may be missing/None."""
    a = getattr(node, attr, None)
    if a is None:
        return default
    v = getattr(a, "value", None)
    return v if v is not None else default


async def fetch_devices(client):
    devices = await client.all(kind="TopologyDevice", prefetch_relationships=True)
    result = []
    for dev in devices:
        name = dev.name.value
        role = None
        if dev.role.peer:
            role = dev.role.peer.name.value
        address = attr_value(dev, "gnmi_address")
        port = attr_value(dev, "gnmi_port", DEFAULT_GNMI_PORT)
        result.append((name, role, address, port))
    return result


async def main():
    client = InfrahubClient(
        address=os.environ["INFRAHUB_ADDRESS"],
        config=Config(api_token=os.environ["INFRAHUB_API_TOKEN"]),
    )

    devices = await fetch_devices(client)
    devices.sort(key=lambda d: d[0])

    if not devices:
        print("WARNING: Infrahub returned zero devices.", file=sys.stderr)
        if os.environ.get("ALLOW_EMPTY") != "1":
            print("Refusing to render an empty target file (set ALLOW_EMPTY=1 to override).", file=sys.stderr)
            sys.exit(2)

    blocks = [HEADER]
    rendered = []
    skipped = []
    for name, role, address, port in devices:
        if not address:
            skipped.append(name)
            continue
        blocks.append(
            TARGET_TMPL.format(
                name=name,
                role=role or "unknown",
                address=address,
                port=port or DEFAULT_GNMI_PORT,
            )
        )
        rendered.append(name)
    blocks.append(SUBSCRIPTIONS)

    with open(OUTPUT_FILE, "w") as f:
        f.write("".join(blocks))

    print(f"Rendered {len(rendered)} targets -> {OUTPUT_FILE}: {', '.join(rendered)}")
    if skipped:
        print(f"NOTE: skipped (no gnmi_address set in Infrahub): {', '.join(skipped)}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())