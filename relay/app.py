#!/usr/bin/env python3
"""
Infrahub -> Gitea webhook relay.

Receives an Infrahub CoreStandardWebhook POST (any payload) and translates it
into a Gitea repository_dispatch call that triggers the sync-targets workflow.

Why this exists: Infrahub's webhook payload and signature headers do not match
what Gitea's /dispatches endpoint expects. Rather than force either side to
bend, this relay accepts whatever Infrahub sends and emits exactly what Gitea
needs. It is intentionally tiny and stateless.

Gitea (1.27) exposes workflow_dispatch, NOT GitHub-style repository_dispatch:
  POST /repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches
with a JSON body of {"ref": "<branch>"}. We call exactly that.

Environment variables (from the relay Secret/Deployment):
  GITEA_DISPATCH_URL   full workflow-dispatch URL, i.e.
                       http://<host>/api/v1/repos/<owner>/<repo>/actions/workflows/<file>/dispatches
  GITEA_TOKEN          Gitea API token with write:repository scope
  DISPATCH_REF         git ref to run the workflow on (default: main)
  SHARED_KEY           optional; if set, verify Infrahub's webhook-signature header
  DEBOUNCE_SECONDS     optional; collapse bursts of events into one dispatch (default: 5)
"""
import os
import time
import hmac
import hashlib
import base64
import threading
import urllib.request
import urllib.error
import json

from flask import Flask, request, jsonify

app = Flask(__name__)

GITEA_DISPATCH_URL = os.environ["GITEA_DISPATCH_URL"]
GITEA_TOKEN = os.environ["GITEA_TOKEN"]
DISPATCH_REF = os.environ.get("DISPATCH_REF", "main")
SHARED_KEY = os.environ.get("SHARED_KEY", "")
DEBOUNCE_SECONDS = float(os.environ.get("DEBOUNCE_SECONDS", "5"))

# --- debounce state -------------------------------------------------------
# Infrahub can emit several events for one logical change (multiple attribute
# mutations). We collapse a burst into a single dispatch so the runner isn't
# hammered. A timer is (re)armed on each event; the dispatch fires once it
# settles.
_lock = threading.Lock()
_timer = None


def _dispatch():
    global _timer
    with _lock:
        _timer = None
    body = json.dumps({"ref": DISPATCH_REF}).encode()
    req = urllib.request.Request(
        GITEA_DISPATCH_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"token {GITEA_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            app.logger.info("Dispatched to Gitea: HTTP %s", resp.status)
    except urllib.error.HTTPError as e:
        app.logger.error("Gitea dispatch failed: HTTP %s - %s", e.code, e.read().decode(errors="replace"))
    except Exception as e:
        app.logger.error("Gitea dispatch error: %s", e)


def _arm_debounce():
    global _timer
    with _lock:
        if _timer is not None:
            _timer.cancel()
        _timer = threading.Timer(DEBOUNCE_SECONDS, _dispatch)
        _timer.daemon = True
        _timer.start()


def _verify_signature(raw_body: bytes) -> bool:
    """Verify Infrahub's webhook-signature if SHARED_KEY is configured.
    Infrahub uses a Standard Webhooks style signature. If verification is not
    desired (lab), leave SHARED_KEY empty to skip.
    """
    if not SHARED_KEY:
        return True
    sig_header = request.headers.get("webhook-signature", "")
    msg_id = request.headers.get("webhook-id", "")
    timestamp = request.headers.get("webhook-timestamp", "")
    if not sig_header or not msg_id or not timestamp:
        return False
    signed_content = f"{msg_id}.{timestamp}.{raw_body.decode()}".encode()
    key = SHARED_KEY.encode()
    expected = base64.b64encode(hmac.new(key, signed_content, hashlib.sha256).digest()).decode()
    # header may contain multiple space-delimited "v1,<sig>" entries
    for part in sig_header.split():
        if "," in part:
            _, candidate = part.split(",", 1)
        else:
            candidate = part
        if hmac.compare_digest(candidate, expected):
            return True
    return False


@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify(status="ok")


@app.route("/webhook", methods=["POST"])
def webhook():
    raw = request.get_data()
    if not _verify_signature(raw):
        return jsonify(error="invalid signature"), 401
    _arm_debounce()
    return jsonify(status="accepted", will_dispatch_in=DEBOUNCE_SECONDS), 202


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)