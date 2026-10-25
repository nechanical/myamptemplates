"""Regenerate embedded installation payloads from their checked-in sources.

Run python scripts/sync_embedded_helpers.py after editing a manager/diagnostics helper or the
default server config. The regression suite checks the resulting bytes.
"""

import base64
import gzip
import json
from pathlib import Path
import re


def main():
    root = Path(__file__).resolve().parents[1]
    path = root / "openstarboundupdates.json"
    stages = json.loads(path.read_text(encoding="utf-8"))
    for stage in stages:
        if stage["UpdateStageName"] in ("Install Unified Mod Helper", "Install Mod Load Order Diagnostics"):
            suffix = "ps1" if stage["UpdateSourcePlatform"] == "Windows" else "sh"
            stem = "openstarboundmanagemods" if stage["UpdateStageName"] == "Install Unified Mod Helper" else "openstarboundmoddiagnostics"
            source = root / (stem + "." + suffix)
        elif stage["UpdateStageName"] == "Install Default Server Config":
            source = root / "openstarbound_server.config"
        else:
            continue
        data = source.read_bytes()
        if stage["UpdateStageName"] in ("Install Unified Mod Helper", "Install Mod Load Order Diagnostics") and stage["UpdateSourcePlatform"] == "Windows":
            # Growing helpers otherwise exceed CreateProcess's 32,767-character limit.
            payload = base64.b64encode(gzip.compress(data, mtime=0)).decode("ascii")
            stage["UpdateSourceArgs"] = (
                '-NoProfile -ExecutionPolicy Bypass -Command "'
                "$ErrorActionPreference='Stop'; $b='" + payload + "'; "
                "$m=[IO.MemoryStream]::new([Convert]::FromBase64String($b)); "
                "$g=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress); "
                "$f=[IO.File]::Create('{{$FullInstanceDir}}" + source.name + "'); "
                'try { $g.CopyTo($f) } finally { $f.Dispose(); $g.Dispose(); $m.Dispose() }"'
            )
            continue
        payload = base64.b64encode(data).decode("ascii")
        arguments, count = re.subn(r"[A-Za-z0-9+/=]{300,}", payload, stage["UpdateSourceArgs"])
        if count != 1:
            raise ValueError("Expected one payload in " + stage["UpdateStageName"])
        stage["UpdateSourceArgs"] = arguments
    path.write_text(json.dumps(stages, indent=4) + "\n", encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
