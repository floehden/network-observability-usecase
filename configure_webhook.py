#!/usr/bin/env python3
"""
Create (idempotently) an Infrahub CoreStandardWebhook that points at the relay
service. The relay handles translation + auth to Gitea, so this webhook is a
plain URL target with a shared_key — exactly the confirmed-working mutation
shape from the Infrahub docs (name / description / url / shared_key).

Usage:
    configure_webhook.py <relay_url> [shared_key]

Reads INFRAHUB_ADDRESS and INFRAHUB_API_TOKEN from the environment.
"""
import os
import sys
import asyncio

from infrahub_sdk import InfrahubClient, Config


async def main(relay_url: str, shared_key: str):
    client = InfrahubClient(
        address=os.environ["INFRAHUB_ADDRESS"],
        config=Config(api_token=os.environ["INFRAHUB_API_TOKEN"]),
    )

    name = "relay-target-sync"

    try:
        existing = await client.filters(kind="CoreStandardWebhook", name__value=name)
        if existing:
            print(f"   ℹ️ Webhook '{name}' already exists, skipping.")
            return
    except Exception as e:
        print(f"   ⚠️ Could not query existing webhooks ({e}); attempting create anyway.")

    try:
        wh = await client.create(
            kind="CoreStandardWebhook",
            name=name,
            description="Fires on changes; relay forwards to Gitea to render targets.",
            url=relay_url,
            shared_key=shared_key or "lab-shared-key",
            branch_scope="all_branches",
            validate_certificates=False,
        )
        await wh.save()
        print(f"   \u2705 Created Infrahub webhook '{name}' -> {relay_url}")
    except Exception as e:
        print(f"   \u274c Failed to create webhook via SDK: {e}", file=sys.stderr)
        print("      Create it manually in the Infrahub UI (Webhooks -> Add):", file=sys.stderr)
        print(f"        Type:  Standard Webhook", file=sys.stderr)
        print(f"        URL:   {relay_url}", file=sys.stderr)
        print(f"        Shared key: {shared_key or 'lab-shared-key'}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: configure_webhook.py <relay_url> [shared_key]", file=sys.stderr)
        sys.exit(1)
    relay = sys.argv[1]
    key = sys.argv[2] if len(sys.argv) > 2 else ""
    asyncio.run(main(relay, key))