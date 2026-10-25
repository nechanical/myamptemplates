"""Run with python -m unittest discover -s tests -p 'test_*.py' -v.

Fixtures invoke the real helpers in disposable instance trees; SteamCMD is a local
argument-checking double. Native Linux runs Bash, Windows also runs PowerShell 5.1.
"""

import base64
import gzip
import json
import io
import lzma
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import struct
import tarfile
import tempfile
import time
import unittest
import zlib


REPO = Path(os.environ.get("AMP_TEST_REPOSITORY", Path(__file__).resolve().parents[1]))
WINDOWS = os.name == "nt"
BASH = shutil.which("bash") if not WINDOWS else r"C:\Program Files\Git\bin\bash.exe"
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


def read_json(name):
    return json.loads((REPO / name).read_text(encoding="utf-8"))


def embedded_bytes(stage):
    payload = re.search(r"[A-Za-z0-9+/=]{300,}", stage["UpdateSourceArgs"])[0]
    data = base64.b64decode(payload)
    return gzip.decompress(data) if "GzipStream" in stage["UpdateSourceArgs"] else data


class TemplateContracts(unittest.TestCase):
    def test_linux_release_and_extractor_agree(self):
        stages = read_json("openstarboundupdates.json")
        download = next(s for s in stages if s["UpdateStageName"] == "OpenStarbound Download"
                        and s["UpdateSourcePlatform"] == "Linux")
        extract = next(s for s in stages if s["UpdateStageName"] == "OpenStarbound Extract")
        self.assertEqual(download["UpdateSourceData"], "OpenStarbound-Linux-Clang-Server.tar.lz")
        self.assertFalse(download["UnzipUpdateSource"])
        self.assertIn(download["UpdateSourceData"], extract["UpdateSourceArgs"])
        self.assertIn("pipefail", extract["UpdateSourceArgs"])
        self.assertFalse(extract["SkipOnFailure"])

    def test_gmod_supplies_rcon_password(self):
        password = next(s for s in read_json("garrys-mod-enhancedconfig.json")
                        if s["FieldName"] == "$RemoteAdminPassword")
        self.assertEqual(password["ParamFieldName"], "rcon_password")
        self.assertTrue(password.get("IncludeInCommandLine", False))
        config = (REPO / "garrys-mod-enhanced.kvp").read_text()
        self.assertIn("{{$FormattedArgs}}", config)
        self.assertIn("App.ApplicationReadyMode=RCONConnected", config)

    def test_embedded_helpers_match_exactly(self):
        stages = read_json("openstarboundupdates.json")
        for platform, suffix in (("Windows", "ps1"), ("Linux", "sh")):
            with self.subTest(platform=platform):
                stage = next(s for s in stages if s["UpdateStageName"] == "Install Unified Mod Helper"
                             and s["UpdateSourcePlatform"] == platform)
                self.assertEqual(embedded_bytes(stage),
                                 (REPO / ("openstarboundmanagemods." + suffix)).read_bytes())
                if platform == "Windows":
                    self.assertLess(len(stage["UpdateSourceArgs"]) + 1024, 32767,
                                    "Embedded installer must fit Windows' command-line limit with path headroom")

    def test_embedded_default_configs_match_exactly(self):
        for stage in read_json("openstarboundupdates.json"):
            if stage["UpdateStageName"] == "Install Default Server Config":
                with self.subTest(platform=stage["UpdateSourcePlatform"]):
                    payload = re.search(r"[A-Za-z0-9+/=]{300,}", stage["UpdateSourceArgs"])[0]
                    self.assertEqual(base64.b64decode(payload), (REPO / "openstarbound_server.config").read_bytes())

    def test_synchronization_failures_stop_update_and_start(self):
        for name in ("openstarboundupdates.json", "openstarboundstart.json"):
            stages = [s for s in read_json(name) if s["UpdateStageName"] == "Synchronize Unified Mods"]
            self.assertEqual(len(stages), 2)
            for stage in stages:
                self.assertFalse(stage["SkipOnFailure"], (name, stage["UpdateSourcePlatform"]))

    def test_linux_collection_parser_is_declared(self):
        config = (REPO / "openstarbound.kvp").read_text()
        packages = re.search(r"Meta.ExtraContainerPackages=(.*)", config)[1]
        self.assertIn("jq", json.loads(packages))

    def test_workshop_timeout_is_wired_from_amp_to_mod_settings(self):
        field = next(row for row in read_json("openstarboundconfig.json") if row["FieldName"] == "ampWorkshopDownloadTimeoutSeconds")
        self.assertEqual(field["DefaultValue"], "900")
        config = next(row for row in read_json("openstarboundmetaconfig.json") if row["ConfigFile"] == "amp_openstarbound_mods.cfg")
        self.assertEqual(config["Subsections"][0]["SettingMappings"]["WorkshopDownloadTimeoutSeconds"], field["FieldName"])
        self.assertEqual(read_json("openstarbound_server.config")[field["FieldName"]], 900)
        self.assertIn("WorkshopDownloadTimeoutSeconds=900", (REPO / "amp_openstarbound_mods.cfg").read_text())


class HelperBehavior:
    suffix = None

    def setUp(self):
        # Git Bash cannot write to this host's sandboxed Windows temp directory.
        self.temporary = tempfile.TemporaryDirectory(prefix=".amp-tests-", dir=REPO)
        self.addCleanup(self.temporary.cleanup)
        self.instance = Path(self.temporary.name) / "instance with spaces"
        self.base = self.instance / "openstarbound" / "server"
        (self.base / "localmods").mkdir(parents=True)
        self.helper = self.instance / ("openstarboundmanagemods." + self.suffix)
        shutil.copyfile(REPO / self.helper.name, self.helper)
        self.config = dict(line.split("=", 1) for line in
                           (REPO / "amp_openstarbound_mods.cfg").read_text().splitlines() if line)
        self.config["DownloadMissingWorkshopItems"] = "false"
        self.powershell_prelude = ""
        self.fixture_bin = self.instance / "fixture-bin"

    def write_config(self):
        (self.base / "amp_openstarbound_mods.cfg").write_text(
            "".join(f"{k}={v}\n" for k, v in self.config.items()), encoding="utf-8")

    def run_helper(self, expect_success=True):
        self.write_config()
        if self.suffix == "ps1":
            script = self.helper
            if self.powershell_prelude:
                script = self.instance / "run-fixture.ps1"
                script.write_text(self.powershell_prelude + "\n& '" + str(self.helper).replace("'", "''") + "' -PreStart\nexit $LASTEXITCODE\n")
            command = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)]
            if script == self.helper:
                command.append("-PreStart")
        else:
            command = [BASH, str(self.helper), "--prestart"]
            if self.fixture_bin.exists():
                bin_path = self.bash_path(self.fixture_bin)
                command = [BASH, "-c", 'export PATH="$1:$PATH"; /bin/bash "$2" --prestart',
                           "fixture", bin_path, str(self.helper)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30, cwd=REPO)
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def pak(self, name, content=None):
        path = self.base / "localmods" / name
        path.write_text(content or name, encoding="utf-8")
        return path

    def targets(self):
        return sorted(p.name for p in (self.base / "mods").iterdir())

    def bash_path(self, path):
        if WINDOWS:
            return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "fixture", str(path)], text=True).strip()
        return str(path)

    def report_section(self, heading):
        report = (self.base / "storage" / "amp_mods_report.txt").read_text(encoding="utf-8-sig")
        lines = []
        for line in report.split(heading + "\n", 1)[1].splitlines():
            if not line.strip():
                break
            lines.append(line)
        return "\n".join(lines).strip()

    def workshop_item(self, item_id, unpacked=False, alternate=False):
        root = self.instance / "openstarbound"
        path = root / "steamapps" / "workshop" / "content" / "211820" / item_id if alternate else root / "workshop" / item_id
        path.mkdir(parents=True, exist_ok=True)
        (path / ("_metadata" if unpacked else "contents.pak")).write_text('{"name":"fixture"}' if unpacked else "fixture assets")
        return path

    def collection_cache(self, cid, members=None):
        path = self.base / "storage" / ("amp_collection_" + cid + ".txt")
        path.parent.mkdir(exist_ok=True)
        if members is not None:
            path.write_bytes("\n".join(members).encode("ascii"))
        return path

    @staticmethod
    def collection_record(cid, members, result=1):
        return {"publishedfileid": cid, "result": result,
                "children": [{"publishedfileid": item} for item in members]}

    def mock_collections(self, records=None, raw=None):
        response = self.instance / "collection-response.json"
        response.write_text(raw if raw is not None else json.dumps({"response": {"collectiondetails": records}}))
        if self.suffix == "ps1":
            self.powershell_prelude = r'''function Invoke-RestMethod {
 param($Method, $Uri, $Body, $TimeoutSec, $ErrorAction)
 $entry = $Body | ConvertTo-Json -Compress
 [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'requests.txt'), $entry + "`n")
 $data = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'collection-response.json'))
 if ($data -eq 'transport-failure') { throw 'fixture transport failure' }
 ConvertFrom-Json -InputObject $data -ErrorAction Stop
}
'''
        else:
            self.fixture_bin.mkdir(exist_ok=True)
            script = self.fixture_bin / "curl"
            script.write_text('''#!/usr/bin/env bash
root="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\\0' "$@" >> "$root/requests.txt"
printf '\\n' >> "$root/requests.txt"
[[ "$(cat "$root/collection-response.json")" != transport-failure ]] || exit 22
cat "$root/collection-response.json"
''', encoding="utf-8", newline="\n")
            script.chmod(0o755)

    def collection_requests(self):
        path = self.instance / "requests.txt"
        if self.suffix == "ps1":
            return [json.loads(line) for line in path.read_text().splitlines()]
        requests = []
        for row in path.read_bytes().splitlines():
            args = row.decode().split("\0")
            requests.append(dict(args[i+1].split("=", 1) for i, arg in enumerate(args)
                                 if arg in ("-d", "--data-urlencode")))
        return requests

    def test_collections_are_batched_and_matched_by_id(self):
        self.config["WorkshopCollectionIDs"] = '["987654321","987654322"]'
        for item in ("123456789", "123456790", "123456791"):
            self.workshop_item(item)
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        self.mock_collections([
            self.collection_record("987654322", ["123456790", "123456789"]),
            self.collection_record("987654321", ["123456791", "123456789", "123456791"]),
            self.collection_record("987654399", ["999999999"]),
        ])
        self.run_helper()
        self.assertEqual(self.collection_requests(), [{"collectioncount": "2", "publishedfileids[0]": "987654321", "publishedfileids[1]": "987654322"}])
        self.assertEqual(self.targets(), [f"amp_{i:04d}_ws_{item}.pak" for i, item in enumerate(("123456789", "123456790", "123456791"), 1)])
        self.assertEqual(set(self.collection_cache("987654321").read_text().splitlines()), {"123456789", "123456791"})
        self.assertEqual(set(self.collection_cache("987654322").read_text().splitlines()), {"123456789", "123456790"})
        self.assertFalse(self.collection_cache("987654399").exists())

    def test_collection_batches_are_bounded(self):
        ids = [str(987654300+i) for i in range(51)]
        self.config["WorkshopCollectionIDs"] = json.dumps(ids)
        self.mock_collections([self.collection_record(cid, []) for cid in reversed(ids)])
        self.run_helper()
        requests = self.collection_requests()
        self.assertEqual([r["collectioncount"] for r in requests], ["50", "1"])
        self.assertEqual([r[f"publishedfileids[{i}]"] for r in requests for i in range(int(r["collectioncount"]))], ids)
        self.assertTrue(all(self.collection_cache(cid).read_bytes() == b"" for cid in ids))

    def test_empty_collection_replaces_cache_and_stays_empty_offline(self):
        cid = "987654321"
        self.config["WorkshopCollectionIDs"] = json.dumps([cid])
        self.workshop_item("123456789")
        self.mock_collections([self.collection_record(cid, ["123456789"])])
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])
        self.mock_collections([self.collection_record(cid, [])])
        self.run_helper()
        self.assertEqual(self.collection_cache(cid).read_bytes(), b"")
        self.assertEqual(self.targets(), [])
        self.mock_collections(raw="transport-failure")
        self.run_helper()
        self.assertEqual(self.targets(), [])
        self.assertEqual(self.report_section("COLLECTIONS THAT COULD NOT BE RESOLVED"), "")

    def test_uncached_collection_failure_is_reported(self):
        cid = "987654321"
        self.config["WorkshopCollectionIDs"] = json.dumps([cid])
        self.mock_collections(raw="transport-failure")
        result = self.run_helper()
        self.assertEqual(self.report_section("COLLECTIONS THAT COULD NOT BE RESOLVED"), cid)
        self.assertIn("Could not resolve collection " + cid, result.stdout + result.stderr)
        self.assertEqual(self.targets(), [])

    def test_partial_batch_failure_preserves_only_failed_membership(self):
        ids = ["987654321", "987654322", "987654323"]
        self.config["WorkshopCollectionIDs"] = json.dumps(ids)
        self.collection_cache(ids[0], ["111111111"])
        self.collection_cache(ids[1], ["123456790"])
        self.workshop_item("123456789")
        self.workshop_item("123456790")
        self.mock_collections([self.collection_record(ids[1], [], result=9), self.collection_record(ids[0], ["123456789"])])
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak", "amp_0002_ws_123456790.pak"])
        self.assertEqual(self.collection_cache(ids[0]).read_text().splitlines(), ["123456789"])
        self.assertEqual(self.collection_cache(ids[1]).read_text().splitlines(), ["123456790"])
        self.assertEqual(self.report_section("COLLECTIONS THAT COULD NOT BE RESOLVED"), ids[2])
        self.assertEqual(len(self.collection_requests()), 1)

    def test_malformed_collection_records_never_erase_cache(self):
        cid = "987654321"
        self.config["WorkshopCollectionIDs"] = json.dumps([cid])
        self.workshop_item("123456789")
        good = self.collection_record(cid, [])
        cases = ["{not json", json.dumps({"response": {"collectiondetails": good}}),
                 json.dumps({"response": {"collectiondetails": [good, good]}}),
                 json.dumps({"response": {"collectiondetails": [{"publishedfileid": cid, "result": 1}]}}),
                 json.dumps({"response": {"collectiondetails": [{**good, "children": [{"publishedfileid": "invalid"}]}]}})]
        for raw in cases:
            with self.subTest(response=raw):
                self.collection_cache(cid, ["123456789"])
                self.mock_collections(raw=raw)
                self.run_helper()
                self.assertEqual(self.collection_cache(cid).read_text().splitlines(), ["123456789"])
                self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def inject_staging_destination_loss(self):
        destination = (self.base / "mods").resolve()
        self.assertTrue(destination.is_relative_to(Path(self.temporary.name).resolve()))
        if self.suffix == "ps1":
            self.powershell_prelude = r'''function New-Item {
 param($ItemType, $Path, $Target, [switch]$Force, $ErrorAction)
 if ($ItemType -in @('HardLink', 'Junction')) {
  $expected = ''' + "'" + str(destination).replace("'", "''") + "'" + r'''
  if ((Split-Path -Parent $Path) -ne $expected) { throw 'Unexpected fault target' }
  if (Test-Path -LiteralPath $expected -PathType Container) { Microsoft.PowerShell.Management\Remove-Item -LiteralPath $expected -ErrorAction Stop }
  [IO.File]::WriteAllText($expected, 'fixture blocking file')
 }
 Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
'''
        else:
            self.fixture_bin.mkdir(exist_ok=True)
            script = self.fixture_bin / "ln"
            script.write_text('''#!/usr/bin/env bash
expected=''' + shlex.quote(self.bash_path(destination)) + '''
target="$2"; [[ "$1" == -s ]] && target="$3"
[[ "$(dirname -- "$target")" == "$expected" ]] || exit 90
if [[ -d "$expected" ]]; then rmdir -- "$expected" || exit 91; fi
printf fixture > "$expected"
exec /usr/bin/ln "$@"
''', encoding="utf-8", newline="\n")
            script.chmod(0o755)

    def test_staging_write_failures_are_fatal_and_never_report_success(self):
        for kind in ("pak", "directory", "bundle", "workshop"):
            with self.subTest(kind=kind):
                source = self.base / "localmods" / "Required"
                if kind == "pak":
                    source = self.pak("Required.pak")
                    key = "local:Required.pak"
                elif kind == "workshop":
                    source = self.workshop_item("123456789")
                    (source / "second.pak").write_text("second")
                    (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
                    key = "ws:123456789"
                else:
                    source.mkdir()
                    (source / ("_metadata" if kind == "directory" else "one.pak")).write_text('{"name":"fixture"}')
                    if kind == "bundle": (source / "two.pak").write_text("second")
                    key = "local:Required"
                try:
                    self.inject_staging_destination_loss()
                    self.run_helper(expect_success=False)
                    self.assertEqual(self.report_section("SUCCESSFULLY STAGED"), "")
                    self.assertIn(key, self.report_section("STAGING FAILURES"))
                    self.assertTrue(source.exists())
                finally:
                    if source.is_dir(): shutil.rmtree(source)
                    else: source.unlink()
                    blocked = self.base / "mods"
                    if blocked.is_file(): blocked.unlink()

    def test_incomplete_workshop_directory_is_downloaded_and_revalidated(self):
        self.install_steamcmd()
        self.config.update(DownloadMissingWorkshopItems="true", WorkshopSteamUsername="fixture_account")
        (self.instance / "openstarbound" / "workshop" / "123456789").mkdir(parents=True)
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        self.run_helper()
        self.assertTrue((self.instance / "steamcmd-args.txt").exists())
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def test_incomplete_workshop_directory_respects_disabled_downloads(self):
        self.install_steamcmd()
        (self.instance / "openstarbound" / "workshop" / "123456789").mkdir(parents=True)
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        self.run_helper()
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())
        self.assertEqual(self.targets(), [])

    def test_failed_workshop_repair_is_not_reported_as_staged(self):
        self.install_steamcmd()
        (self.instance / "fail-download").touch()
        self.config.update(DownloadMissingWorkshopItems="true", WorkshopSteamUsername="fixture_account")
        (self.instance / "openstarbound" / "workshop" / "123456789").mkdir(parents=True)
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        self.run_helper(expect_success=False)
        self.assertTrue((self.instance / "steamcmd-args.txt").exists())
        self.assertEqual(self.targets(), [])
        self.assertEqual(self.report_section("SUCCESSFULLY STAGED"), "")
        self.assertIn("ws:123456789", self.report_section("MISSING/UNUSABLE MANAGED SOURCES"))
        self.assertIn("ws:123456789", self.report_section("WORKSHOP DOWNLOAD FAILURES"))

    def test_usable_workshop_sources_do_not_download(self):
        self.install_steamcmd()
        self.config.update(DownloadMissingWorkshopItems="true", WorkshopSteamUsername="fixture_account")
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        for unpacked in (False, True):
            with self.subTest(unpacked=unpacked):
                source = self.workshop_item("123456789", unpacked=unpacked)
                self.run_helper()
                self.assertFalse((self.instance / "steamcmd-args.txt").exists())
                self.assertEqual(self.targets(), ["amp_0001_ws_123456789" + ("" if unpacked else ".pak")])
                shutil.rmtree(source)

    def test_incomplete_primary_source_does_not_hide_valid_alternate(self):
        (self.instance / "openstarbound" / "workshop" / "123456789").mkdir(parents=True)
        self.workshop_item("123456789", alternate=True)
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]')
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def test_empty_unified_list_uses_legacy_order(self):
        self.pak("A.pak")
        self.pak("B.pak")
        self.config["UnifiedModPreference"] = "[ ]"
        self.config["ModLoadOrder"] = '["local:B.pak","local:A.pak"]'
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_local_B.pak", "amp_0002_local_A.pak"])

    def test_disable_reconciles_existing_staging_without_broad_pruning(self):
        self.pak("A.pak")
        self.pak("Z.pak")
        self.config["PruneManagedMods"] = "false"
        self.run_helper()
        mods = self.base / "mods"
        (mods / "amp_unrecognized.pak").write_text("keep")
        (mods / "manual.pak").write_text("keep")
        self.config["DisabledLocalMods"] = '["A.pak"]'
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_local_Z.pak", "amp_unrecognized.pak", "manual.pak"])
        self.assertTrue((self.base / "localmods" / "A.pak").exists())

    def test_reorder_and_removed_source_leave_no_old_copies(self):
        self.pak("A.pak")
        self.pak("B.pak")
        self.config["PruneManagedMods"] = "false"
        self.run_helper()
        self.config["UnifiedModPreference"] = '["local:B.pak","local:A.pak"]'
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_local_B.pak", "amp_0002_local_A.pak"])
        (self.base / "localmods" / "B.pak").unlink()
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_local_A.pak"])

    def test_overlapping_source_is_rejected_before_pruning(self):
        source = self.base / "mods" / "amp_private_sources"
        source.mkdir(parents=True)
        original = source / "Private.pak"
        original.write_text("irreplaceable fixture")
        self.config["LocalModsDirectory"] = "mods/amp_private_sources"
        self.run_helper(expect_success=False)
        self.assertEqual(original.read_text(), "irreplaceable fixture")

    def test_source_cannot_be_staging_or_its_ancestor(self):
        for directory in ("mods", "."):
            with self.subTest(directory=directory):
                self.config["LocalModsDirectory"] = directory
                self.run_helper(expect_success=False)

    def test_normal_custom_directory_still_stages(self):
        custom = self.base / "private" / "sources"
        custom.mkdir(parents=True)
        (custom / "Private.pak").write_text("private")
        self.config["LocalModsDirectory"] = "private/sources"
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_local_Private.pak"])

    def make_directory_link(self, path, target):
        if WINDOWS:
            script = "New-Item -ItemType Junction -Path '" + str(path).replace("'", "''") + "' -Target '" + str(target).replace("'", "''") + "' | Out-Null"
            subprocess.run([POWERSHELL, "-NoProfile", "-Command", script], check=True, capture_output=True)
        else:
            path.symlink_to(target, target_is_directory=True)

    def test_source_alias_cannot_bypass_overlap_check(self):
        source = self.base / "mods" / "amp_private_sources"
        source.mkdir(parents=True)
        original = source / "Private.pak"
        original.write_text("original")
        self.make_directory_link(self.base / "source-link", source)
        self.config["LocalModsDirectory"] = "source-link"
        self.run_helper(expect_success=False)
        self.assertEqual(original.read_text(), "original")

    def test_staging_alias_cannot_point_into_sources(self):
        original = self.pak("Private.pak")
        self.make_directory_link(self.base / "mods", self.base / "localmods")
        self.run_helper(expect_success=False)
        self.assertEqual(original.read_text(), "Private.pak")

    def test_unpacked_source_survives_repeated_syncs(self):
        source = self.base / "localmods" / "Unpacked"
        source.mkdir()
        (source / "_metadata").write_text('{"name":"fixture"}')
        (source / "asset.txt").write_text("source content")
        for prune in ("true", "false"):
            self.config["PruneManagedMods"] = prune
            self.run_helper()
            self.run_helper()
            self.assertEqual((source / "asset.txt").read_text(), "source content")
            self.assertEqual((self.base / "mods" / "amp_0001_local_Unpacked" / "asset.txt").read_text(), "source content")

    def test_missing_cached_identity_is_actionable_without_launching_steamcmd(self):
        self.install_steamcmd()
        cache = self.instance / "config"
        cache.mkdir()
        (cache / "config.vdf").write_text('"ConnectCache" { }')
        self.config["DownloadMissingWorkshopItems"] = "true"
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]\n')
        result = self.run_helper(expect_success=False)
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())
        self.assertIn("Workshop Steam Username", result.stdout + result.stderr)

    def test_missing_workshop_download_passes_explicit_username(self):
        self.install_steamcmd()
        self.config["DownloadMissingWorkshopItems"] = "true"
        self.config["WorkshopSteamUsername"] = "fixture_account"
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]\n')
        self.run_helper()
        self.assertEqual((self.instance / "steamcmd-args.txt").read_text().splitlines(),
                         ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "1",
                          "+login", "fixture_account", "+workshop_download_item", "211820", "123456789", "validate", "+quit"])
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def test_missing_workshop_download_reuses_single_cached_identity(self):
        self.install_steamcmd()
        cache = self.instance / "config"
        cache.mkdir()
        (cache / "config.vdf").write_text('"InstallConfigStore" { "ConnectCache" { "fixture_account" "fake-token-never-log" } }')
        self.config["DownloadMissingWorkshopItems"] = "true"
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]\n')
        result = self.run_helper()
        self.assertNotIn("fake-token-never-log", result.stdout + result.stderr)
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def test_ambiguous_cached_identity_does_not_guess_or_run_steamcmd(self):
        self.install_steamcmd()
        cache = self.instance / "config"
        cache.mkdir()
        (cache / "config.vdf").write_text('"ConnectCache" { "first" "fake1" "second" "fake2" }')
        self.config["DownloadMissingWorkshopItems"] = "true"
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]\n')
        result = self.run_helper(expect_success=False)
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())
        self.assertIn("Workshop Steam Username", result.stdout + result.stderr)

    def prepare_automatic_download(self, item="123456789"):
        self.install_steamcmd()
        self.config.update(DownloadMissingWorkshopItems="true", WorkshopSteamUsername="fixture_account")
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["' + item + '"]')

    def test_steamcmd_output_is_visible_and_input_is_closed(self):
        self.prepare_automatic_download("869900472")
        (self.instance / "check-stdin").touch()
        self.config["WorkshopDownloadTimeoutSeconds"] = "2"
        result = self.run_helper()
        self.assertIn("fixture download progress", result.stdout)
        self.assertIn("fixture stderr progress", result.stderr)
        self.assertEqual(self.targets(), ["amp_0001_ws_869900472.pak"])

    def test_workshop_timeout_stops_download_tree_and_reports_failure(self):
        self.prepare_automatic_download()
        (self.instance / "stall-download").touch()
        self.config["WorkshopDownloadTimeoutSeconds"] = "2"
        started = time.monotonic()
        result = self.run_helper(expect_success=False)
        self.assertLess(time.monotonic() - started, 15, result.stdout + result.stderr)
        self.assertIn("timed out after 2s", result.stdout + result.stderr)
        self.assertEqual(self.report_section("SUCCESSFULLY STAGED"), "")
        self.assertEqual(self.report_section("WORKSHOP DOWNLOAD FAILURES"), "ws:123456789")
        self.assertTrue((self.instance / "child-started").exists())
        # The double's child writes this after three seconds if it survives.
        time.sleep(3.5)
        self.assertFalse((self.instance / "orphan-survived").exists())
        self.assertFalse((self.instance / "openstarbound" / "workshop" / "123456789" / "contents.pak").exists())

    def test_workshop_timeout_can_allow_a_slow_successful_download(self):
        self.prepare_automatic_download()
        (self.instance / "slow-download").touch()
        self.config["WorkshopDownloadTimeoutSeconds"] = "5"
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])

    def test_zero_exit_without_workshop_assets_is_fatal(self):
        self.prepare_automatic_download()
        (self.instance / "no-assets").touch()
        result = self.run_helper(expect_success=False)
        self.assertIn("did not produce usable local assets", result.stdout + result.stderr)
        self.assertEqual(self.report_section("WORKSHOP DOWNLOAD FAILURES"), "ws:123456789")

    def test_steamcmd_adjacent_library_is_discovered_after_download(self):
        self.prepare_automatic_download()
        (self.instance / "own-library").touch()
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])
        self.assertTrue((self.instance / "steamapps" / "workshop" / "content" / "211820" / "123456789" / "contents.pak").exists())

    def test_existing_steamcmd_adjacent_library_avoids_download(self):
        self.prepare_automatic_download()
        source = self.instance / "steamapps" / "workshop" / "content" / "211820" / "123456789"
        source.mkdir(parents=True)
        (source / "contents.pak").write_text("already downloaded")
        self.run_helper()
        self.assertEqual(self.targets(), ["amp_0001_ws_123456789.pak"])
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())


@unittest.skipUnless(WINDOWS, "PowerShell 5.1 helper targets Windows")
class WindowsHelper(HelperBehavior, unittest.TestCase):
    suffix = "ps1"

    def install_steamcmd(self):
        # Compile a tiny executable so the complete native-process boundary is tested.
        source = r'''using System; using System.IO; using System.Diagnostics; using System.Threading;
class FakeSteamCmd { static int Main(string[] args) {
 string root = AppDomain.CurrentDomain.BaseDirectory;
 if (args.Length == 1 && args[0] == "--late-child") {
  Thread.Sleep(3000); File.WriteAllText(Path.Combine(root, "orphan-survived"), "child survived"); return 0;
 }
 File.WriteAllLines(Path.Combine(root, "steamcmd-args.txt"), args);
 Console.WriteLine("fixture download progress"); Console.Error.WriteLine("fixture stderr progress");
 if (args.Length != 11 || args[0] != "+@ShutdownOnFailedCommand" || args[1] != "1" || args[2] != "+@NoPromptForPassword" || args[3] != "1" || args[4] != "+login" || args[5] != "fixture_account") return 2;
 if (File.Exists(Path.Combine(root, "check-stdin")) && Console.ReadLine() != null) return 3;
 if (File.Exists(Path.Combine(root, "fail-download"))) return 2;
 if (File.Exists(Path.Combine(root, "stall-download"))) {
  var child = new ProcessStartInfo(Path.Combine(root, "steamcmd.exe"), "--late-child");
  child.UseShellExecute = false; child.CreateNoWindow = true; Process.Start(child);
  File.WriteAllText(Path.Combine(root, "child-started"), "started");
  Thread.Sleep(10000);
 }
 if (File.Exists(Path.Combine(root, "slow-download"))) Thread.Sleep(2000);
 if (File.Exists(Path.Combine(root, "no-assets"))) return 0;
 string dir = File.Exists(Path.Combine(root, "own-library")) ? Path.Combine(root, "steamapps", "workshop", "content", "211820", args[8]) : Path.Combine(root, "openstarbound", "workshop", args[8]);
 Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "contents.pak"), "fixture"); return 0;
} }'''
        script = "Add-Type -TypeDefinition @'\n" + source + "\n'@ -OutputAssembly '" + str(self.instance / "steamcmd.exe").replace("'", "''") + "' -OutputType ConsoleApplication"
        result = subprocess.run([POWERSHELL, "-NoProfile", "-EncodedCommand",
                                 base64.b64encode(script.encode("utf-16le")).decode()],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(BASH and Path(BASH).exists(), "Bash is unavailable")
class BashHelper(HelperBehavior, unittest.TestCase):
    suffix = "sh"

    def install_steamcmd(self):
        (self.instance / "steamcmd.sh").write_text('''#!/usr/bin/env bash
root="$(cd "$(dirname "$0")" && pwd)"
printf '%s\\n' "$@" > "$root/steamcmd-args.txt"
echo 'fixture download progress'
echo 'fixture stderr progress' >&2
[[ "$#" == 11 && "$1" == +@ShutdownOnFailedCommand && "$2" == 1 && "$3" == +@NoPromptForPassword && "$4" == 1 && "$5" == +login && "$6" == fixture_account ]] || exit 2
if [[ -f "$root/check-stdin" ]]; then
  if IFS= read -r input; then exit 3; fi
fi
[[ ! -f "$root/fail-download" ]] || exit 2
if [[ -f "$root/stall-download" ]]; then
  (sleep 3; printf survived > "$root/orphan-survived") &
  printf started > "$root/child-started"
  sleep 10
fi
[[ ! -f "$root/slow-download" ]] || sleep 2
[[ ! -f "$root/no-assets" ]] || exit 0
dir="$root/openstarbound/workshop/$9"
[[ ! -f "$root/own-library" ]] || dir="$root/steamapps/workshop/content/211820/$9"
mkdir -p "$dir"
printf fixture > "$dir/contents.pak"
''', encoding="utf-8")


class InstallStages(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix=".amp-tests-", dir=REPO)
        self.addCleanup(self.temporary.cleanup)
        self.instance = Path(self.temporary.name) / "instance with spaces"
        self.base = self.instance / "openstarbound" / "server"
        (self.base / "storage").mkdir(parents=True)

    def run_stage(self, name, platform):
        stage = next(s for s in read_json("openstarboundupdates.json")
                     if s["UpdateStageName"] == name and s["UpdateSourcePlatform"] == platform)
        def path_value(path):
            if platform == "Linux" and WINDOWS:
                return subprocess.check_output([BASH, "-c", 'cygpath -u "$1"', "test", str(path)], text=True).strip() + "/"
            return str(path) + os.sep
        args = stage["UpdateSourceArgs"]
        for key, path in (("FullInstanceDir", self.instance), ("FullRootDir", self.instance / "openstarbound"), ("FullBaseDir", self.base)):
            args = args.replace("{{$" + key + "}}", path_value(path))
        if platform == "Windows":
            command = '"' + POWERSHELL + '" ' + args
        elif WINDOWS:
            command = '"' + BASH + '" ' + args
        else:
            command = [BASH] + shlex.split(args)
        return subprocess.run(command, cwd=self.instance, capture_output=True, text=True, timeout=30)

    def test_config_creation_and_preservation(self):
        for platform in (("Windows", "Linux") if WINDOWS else ("Linux",)):
            with self.subTest(platform=platform):
                path = self.base / "storage" / "starbound_server.config"
                if path.exists():
                    path.unlink()
                result = self.run_stage("Install Default Server Config", platform)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(json.loads(path.read_text()), read_json("openstarbound_server.config"))
                path.write_text('{"serverName":"preserve existing"}')
                result = self.run_stage("Install Default Server Config", platform)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(path.read_text(), '{"serverName":"preserve existing"}')

    def test_packed_assets_copy_and_missing_source_failure(self):
        source = self.instance / "openstarbound" / "211820" / "assets" / "packed.pak"
        source.parent.mkdir(parents=True)
        for platform in (("Windows", "Linux") if WINDOWS else ("Linux",)):
            with self.subTest(platform=platform):
                source.write_text("fixture assets")
                result = self.run_stage("Install packed.pak", platform)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.base / "assets" / "packed.pak").read_text(), "fixture assets")
                source.unlink()
                result = self.run_stage("Install packed.pak", platform)
                self.assertNotEqual(result.returncode, 0)

    @unittest.skipUnless(not WINDOWS and shutil.which("lzip"), "Native Linux extraction requires lzip")
    def test_linux_extracts_archive_and_rejects_corruption(self):
        contents = io.BytesIO()
        with tarfile.open(fileobj=contents, mode="w") as archive:
            data = b"fixture Linux executable"
            entry = tarfile.TarInfo("server_distribution/linux/starbound_server")
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
        path = self.base / "OpenStarbound-Linux-Clang-Server.tar.lz"
        tar_bytes = contents.getvalue()
        compressed = lzma.compress(tar_bytes, format=lzma.FORMAT_RAW, filters=[
            {"id": lzma.FILTER_LZMA1, "dict_size": 1 << 23, "lc": 3, "lp": 0, "pb": 2}])
        # Lzip v1 header, raw LZMA stream, then CRC32/size/member-size trailer.
        archive_bytes = b"LZIP\x01\x17" + compressed
        archive_bytes += struct.pack("<IQQ", zlib.crc32(tar_bytes), len(tar_bytes), len(archive_bytes) + 20)
        path.write_bytes(archive_bytes)
        result = self.run_stage("OpenStarbound Extract", "Linux")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "linux" / "starbound_server").read_bytes(), data)
        self.assertFalse(path.exists())
        path.write_bytes(b"corrupt archive")
        result = self.run_stage("OpenStarbound Extract", "Linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.exists())

    def test_helper_installation_emits_standalone_bytes(self):
        # Git Bash truncates long -c strings on this Windows host. Exercise each
        # installer on its native OS; helper behavior still runs in Git Bash too.
        for platform, suffix in ((("Windows", "ps1"),) if WINDOWS else (("Linux", "sh"),)):
            with self.subTest(platform=platform):
                result = self.run_stage("Install Unified Mod Helper", platform)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.instance / ("openstarboundmanagemods." + suffix)).read_bytes(),
                                 (REPO / ("openstarboundmanagemods." + suffix)).read_bytes())

    @unittest.skipUnless(WINDOWS, "Windows executable layout")
    def test_windows_release_layout_normalization(self):
        executable = self.base / "server_distribution" / "win" / "starbound_server.exe"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture executable")
        result = self.run_stage("Normalize Windows Release Layout", "Windows")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.base / "win" / executable.name).read_text(), "fixture executable")
        self.assertFalse((self.base / "server_distribution").exists())


if __name__ == "__main__":
    unittest.main()
