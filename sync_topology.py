import os
import yaml
import asyncio
from infrahub_sdk import InfrahubClient, Config

CLAB_FILE = os.environ.get("CLAB_FILE", "YAML/st.clab.yml")
REPO_LOCATION = "http://gitea-http.gitea.svc.cluster.local:3000/admin/infrahub-sync.git"

# Groups we import as network devices
DEVICE_GROUPS = {"spine", "leaf"}

# The host IP that exposes the containerlab gNMI ports. Today all devices are
# reachable via this single docker-host IP + their mapped host port. Override
# with GNMI_HOST_IP to point elsewhere. Later, you can instead store each
# device's real mgmt IP (see USE_MGMT_IP below).
GNMI_HOST_IP = os.environ.get("GNMI_HOST_IP", "192.168.139.126")

# If set to "1", store each node's mgmt-ipv4 as the gnmi_address instead of the
# shared host IP (for when devices become directly reachable). Port then
# defaults to the in-container gNMI port (57400) unless a host mapping exists.
USE_MGMT_IP = os.environ.get("USE_MGMT_IP", "0") == "1"

# Default in-container gNMI port for SR Linux
DEFAULT_GNMI_PORT = 57400


def parse_host_port(node_data):
    """Extract the host-side port from a clab 'ports' entry like '57401:57400'.
    Returns the host port (left side) as int, or None if no mapping."""
    ports = node_data.get("ports", [])
    for mapping in ports:
        # mapping is "HOSTPORT:CONTAINERPORT"
        parts = str(mapping).split(":")
        if len(parts) == 2:
            try:
                return int(parts[0])
            except ValueError:
                continue
    return None


def resolve_address_and_port(node_data):
    """Decide what gnmi_address/gnmi_port to store for a node."""
    host_port = parse_host_port(node_data)
    if USE_MGMT_IP:
        addr = node_data.get("mgmt-ipv4", GNMI_HOST_IP)
        # when dialing the device directly, use the container gNMI port
        port = DEFAULT_GNMI_PORT
    else:
        addr = GNMI_HOST_IP
        # dialing the docker host, use the mapped host port
        port = host_port if host_port is not None else DEFAULT_GNMI_PORT
    return addr, port


async def main():
    client = InfrahubClient(
        address=os.environ["INFRAHUB_ADDRESS"],
        config=Config(api_token=os.environ["INFRAHUB_API_TOKEN"]),
    )

    print("🔗 1. Connecting Infrahub to Gitea Repository...")
    existing_repo = await client.filters(kind="CoreRepository", name__value="infrahub-sync")
    if existing_repo:
        print("   ℹ️ Repository already linked, skipping.")
    else:
        repo = await client.create(
            kind="CoreRepository",
            name="infrahub-sync",
            location=REPO_LOCATION,
            commit="main",
        )
        await repo.save()
        print("   ✅ Repository Linked!")

    print("\n📖 2. Parsing Containerlab Topology...")
    with open(CLAB_FILE, "r") as f:
        clab = yaml.safe_load(f)

    topology = clab.get("topology", {})
    nodes = topology.get("nodes", {})
    links = topology.get("links", [])
    print(f"   Found {len(nodes)} nodes and {len(links)} links in the topology.")

    print("\n🏗️ 3. Creating Platforms and Roles...")
    platform_srl = await get_or_create(client, "TopologyPlatform", "nokia_srlinux")
    role_spine = await get_or_create(client, "TopologyRole", "spine")
    role_leaf = await get_or_create(client, "TopologyRole", "leaf")
    roles = {"spine": role_spine, "leaf": role_leaf}

    print("\n🖥️ 4. Creating Devices (with gNMI address/port)...")
    device_objs = {}
    for node_name, node_data in nodes.items():
        group = node_data.get("group", "")
        if group in DEVICE_GROUPS:
            addr, port = resolve_address_and_port(node_data)
            dev = await get_or_create(client, "TopologyDevice", node_name)
            dev.platform = platform_srl
            dev.role = roles[group]
            dev.gnmi_address.value = addr
            dev.gnmi_port.value = port
            await dev.save()
            device_objs[node_name] = dev
            print(f"   Created {group.capitalize()}: {node_name} -> {addr}:{port}")

    print("\n🔌 5. Creating Interfaces and Wiring Connections...")
    interfaces_created = {}

    async def get_or_create_intf(device_name, intf_name):
        interfaces_created.setdefault(device_name, {})
        if intf_name not in interfaces_created[device_name]:
            intf = await client.create(
                kind="TopologyInterface",
                name=intf_name,
                device=device_objs[device_name],
            )
            await intf.save()
            interfaces_created[device_name][intf_name] = intf
        return interfaces_created[device_name][intf_name]

    for link in links:
        endpoints = link.get("endpoints")
        if not endpoints or len(endpoints) != 2:
            continue
        dev1_name, intf1_name = endpoints[0].split(":")
        dev2_name, intf2_name = endpoints[1].split(":")
        if dev1_name in device_objs and dev2_name in device_objs:
            intf1 = await get_or_create_intf(dev1_name, intf1_name)
            intf2 = await get_or_create_intf(dev2_name, intf2_name)
            intf1.connected_endpoint = intf2
            await intf1.save()
            print(f"   Linked {dev1_name} ({intf1_name}) <---> {dev2_name} ({intf2_name})")

    print("\n🎉 Success! Containerlab topology is now live in Infrahub!")


async def get_or_create(client, kind, name, **attrs):
    existing = await client.filters(kind=kind, name__value=name)
    if existing:
        return existing[0]
    obj = await client.create(kind=kind, name=name, **attrs)
    await obj.save()
    return obj


if __name__ == "__main__":
    asyncio.run(main())