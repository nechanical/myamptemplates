"""Regenerate embedded installation payloads from their checked-in sources.

Run python scripts/sync_embedded_helpers.py after editing either helper or the
default server config. The regression suite checks the resulting bytes.
"""

import base64
import json
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parents[1]
    path = root / "openstarboundupdates.json"
    stages = json.loads(path.read_text(encoding="utf-8"))
    for stage in stages:
        if stage["UpdateStageName"] == "Install Unified Mod Helper":
            suffix = "ps1" if stage["UpdateSourcePlatform"] == "Windows" else "sh"
            source = root / ("openstarboundmanagemods." + suffix)
        elif stage["UpdateStageName"] == "Install Default Server Config":
            source = root / "openstarbound_server.config"
        else:
            continue
        payload = base64.b64encode(source.read_bytes()).decode("ascii")
        arguments, count = re.subn(r"[A-Za-z0-9+/=]{300,}", payload, stage["UpdateSourceArgs"])
        if count != 1:
            raise ValueError("Expected one payload in " + stage["UpdateStageName"])
        stage["UpdateSourceArgs"] = arguments
    path.write_text(json.dumps(stages, indent=4) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
