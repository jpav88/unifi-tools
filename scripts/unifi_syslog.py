#!/usr/bin/env python3
"""UniFi remote syslog receiver with self-install for macOS launchd."""

import argparse
import logging
import os
import plistlib
import signal
import socketserver
import subprocess
import sys
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path

LABEL = "com.unifi.syslog"
DEFAULT_PORT = 5514
LOG_DIR = Path.home() / "Library" / "Logs" / "unifi-syslog"
LOG_FILE = LOG_DIR / "unifi.log"
MAX_BYTES = 1024 * 1024 * 1024  # 1 GB per file
BACKUP_COUNT = 10  # keep 10 rotated files (~10 GB total, ~3 months)
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"

# Messages matching these substrings are dropped before logging.
# Reduces log volume from noisy but non-actionable events.
FILTER_SUBSTRINGS = [
    "could not start ubnt-protocol",
    "ubnt_protocol.ubnt_protocol_init()",
    "ubnt_protocol.info: No such file",
    "wevent.service: Scheduled restart job",
    "wevent.service: Succeeded",
    "Stopped wevent service",
    "Starting wevent service",
    "Started wevent service",
    "L2UF subsystem initialized",
    "L2UF subsystem cleaned up",
    "Successfully initialized VAP tracking",
    "UBNT_DEVICE[",
]


def should_filter(message):
    """Return True if message matches a known spam pattern."""
    return any(s in message for s in FILTER_SUBSTRINGS)


def setup_logger(daemon=False):
    """Configure rotating file + optional console logger."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("unifi_syslog")
    logger.setLevel(logging.INFO)

    file_handler = RotatingFileHandler(
        LOG_FILE, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT
    )
    file_handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(file_handler)

    if not daemon:
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(
            logging.Formatter("%(asctime)s %(message)s", datefmt="%H:%M:%S")
        )
        logger.addHandler(console_handler)

    return logger


class SyslogHandler(socketserver.BaseRequestHandler):
    """Handle incoming syslog UDP messages."""

    def handle(self):
        data = self.request[0].strip()
        try:
            message = data.decode("utf-8", errors="replace")
        except Exception:
            message = str(data)
        if should_filter(message):
            return
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        source = self.client_address[0]
        self.server.logger.info("%s [%s] %s", timestamp, source, message)


class SyslogServer(socketserver.UDPServer):
    """UDP syslog server with logger attached."""

    allow_reuse_address = True

    def __init__(self, port, logger):
        self.logger = logger
        super().__init__(("0.0.0.0", port), SyslogHandler)


def run_server(port, daemon=False):
    """Start the syslog listener."""
    logger = setup_logger(daemon=daemon)
    server = SyslogServer(port, logger)

    def shutdown(signum, frame):
        logger.info("Shutting down syslog receiver")
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    print(f"UniFi syslog receiver listening on UDP port {port}")
    print(f"Logging to {LOG_FILE}")
    logger.info("UniFi syslog receiver started on UDP port %d", port)
    server.serve_forever()


def install(port):
    """Install launchd plist and start the service."""
    script_path = os.path.abspath(__file__)

    plist = {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, script_path, "--port", str(port), "--daemon"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": str(LOG_DIR / "stdout.log"),
        "StandardErrorPath": str(LOG_DIR / "stderr.log"),
    }

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)

    # Unload if already loaded
    subprocess.run(
        ["launchctl", "unload", str(PLIST_PATH)],
        capture_output=True,
    )

    with open(PLIST_PATH, "wb") as f:
        plistlib.dump(plist, f)

    result = subprocess.run(
        ["launchctl", "load", str(PLIST_PATH)],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print(f"Installed and started {LABEL}")
        print(f"  Plist: {PLIST_PATH}")
        print(f"  Logs:  {LOG_FILE}")
        print(f"  Port:  {port}")
    else:
        print(f"Failed to load: {result.stderr}", file=sys.stderr)
        sys.exit(1)


def uninstall():
    """Stop the service and remove the plist."""
    subprocess.run(
        ["launchctl", "unload", str(PLIST_PATH)],
        capture_output=True,
    )
    if PLIST_PATH.exists():
        PLIST_PATH.unlink()
        print(f"Removed {PLIST_PATH}")
    else:
        print("Plist not found, nothing to remove")
    print(f"Logs retained at {LOG_DIR}")


def main():
    parser = argparse.ArgumentParser(description="UniFi syslog receiver")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="UDP port (default: 5514)")
    parser.add_argument("--install", action="store_true", help="Install as launchd service and start")
    parser.add_argument("--uninstall", action="store_true", help="Stop and remove launchd service")
    parser.add_argument("--daemon", action="store_true", help="Run as daemon (no console output)")
    args = parser.parse_args()

    if args.install:
        install(args.port)
    elif args.uninstall:
        uninstall()
    else:
        run_server(args.port, daemon=args.daemon)


if __name__ == "__main__":
    main()
