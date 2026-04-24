"""Lambda SFTP egress test harness.

TEST_MODE=tcp   — TCP connect to SFTP_HOST:SFTP_PORT, 3-second timeout. Proves
                   the network path (subnet → GWLBe → CC → ZIA → internet) is open.
                   No paramiko required.

TEST_MODE=sftp  — Full paramiko-driven SFTP: connect, LIST, upload a 64-byte
                   marker file, disconnect. Requires the deployment zip to
                   include paramiko (built by scripts/build-lambda.sh).

Credentials loaded from Secrets Manager secret at $SECRET_NAME:
  {"host": "...", "port": 22, "username": "...", "password": "..."}
"""
import json
import logging
import os
import socket
import time
from datetime import datetime, timezone

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

TEST_MODE   = os.environ.get("TEST_MODE", "tcp").lower()
SECRET_NAME = os.environ.get("SECRET_NAME", "")

_sm = boto3.client("secretsmanager")
_creds_cache = {}


def _creds():
    if not _creds_cache and SECRET_NAME:
        raw = _sm.get_secret_value(SecretId=SECRET_NAME)["SecretString"]
        _creds_cache.update(json.loads(raw))
    return _creds_cache


def _tcp_test(host, port, timeout=5):
    t0 = time.time()
    s = socket.create_connection((host, port), timeout=timeout)
    banner = b""
    try:
        s.settimeout(2)
        banner = s.recv(128)
    except (socket.timeout, OSError):
        pass
    finally:
        s.close()
    return {
        "mode": "tcp",
        "host": host,
        "port": port,
        "connect_ms": int((time.time() - t0) * 1000),
        "banner": banner.decode("utf-8", "replace").strip() if banner else None,
        "ok": True,
    }


def _sftp_test(host, port, username, password):
    import paramiko  # deferred import — avoids cold-start penalty in tcp mode

    t0 = time.time()
    transport = paramiko.Transport((host, port))
    transport.connect(username=username, password=password)
    sftp = paramiko.SFTPClient.from_transport(transport)
    connect_ms = int((time.time() - t0) * 1000)

    t0 = time.time()
    try:
        listing = sftp.listdir(".")
    except Exception as e:
        listing = f"<listdir failed: {e}>"
    list_ms = int((time.time() - t0) * 1000)

    marker = f"ztw-lambda-egress-probe-{datetime.now(timezone.utc).isoformat()}\n".encode()
    remote_name = f"ztw-lambda-probe-{int(time.time())}.txt"
    upload_ms = None
    upload_error = None
    try:
        t0 = time.time()
        with sftp.file(remote_name, "wb") as f:
            f.write(marker)
        upload_ms = int((time.time() - t0) * 1000)
    except Exception as e:
        upload_error = str(e)

    sftp.close()
    transport.close()

    return {
        "mode": "sftp",
        "host": host,
        "port": port,
        "connect_ms": connect_ms,
        "listdir_ms": list_ms,
        "listing_preview": listing[:5] if isinstance(listing, list) else listing,
        "uploaded": remote_name if upload_ms else None,
        "upload_ms": upload_ms,
        "upload_error": upload_error,
        "ok": upload_ms is not None,
    }


def lambda_handler(event, _ctx):
    log.info("event: %s", json.dumps(event))
    creds = _creds()

    host = event.get("host") or creds.get("host") or os.environ.get("SFTP_HOST")
    port = int(event.get("port") or creds.get("port") or os.environ.get("SFTP_PORT", 22))

    if not host:
        return {"ok": False, "error": "no SFTP host configured (event.host, secret.host, or SFTP_HOST env)"}

    mode = event.get("mode", TEST_MODE).lower()
    log.info("mode=%s host=%s port=%d", mode, host, port)

    try:
        if mode == "tcp":
            result = _tcp_test(host, port)
        elif mode == "sftp":
            if not creds.get("username") or not creds.get("password"):
                return {"ok": False, "error": "sftp mode requires username+password in secret"}
            result = _sftp_test(host, port, creds["username"], creds["password"])
        else:
            return {"ok": False, "error": f"unknown mode: {mode}"}
    except Exception as e:
        log.exception("test failed")
        return {"ok": False, "mode": mode, "host": host, "port": port, "error": str(e)}

    log.info("result: %s", json.dumps(result))
    return result
