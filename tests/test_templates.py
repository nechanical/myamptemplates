"""Run with python -m unittest discover -s tests -p 'test_*.py' -v.

Fixtures invoke the real helpers in disposable instance trees; SteamCMD is a local
argument-checking double. Native Linux runs Bash, Windows also runs PowerShell 5.1.
"""

import base64
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
import unittest
import zlib


REPO = Path(os.environ.get("AMP_TEST_REPOSITORY", Path(__file__).resolve().parents[1]))
WINDOWS = os.name == "nt"
BASH = shutil.which("bash") if not WINDOWS else r"C:\Program Files\Git\bin\bash.exe"
POWERSHELL = r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"


def read_json(name):
    return json.loads((REPO / name).read_text(encoding="utf-8"))


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
                payload = re.search(r"[A-Za-z0-9+/=]{300,}", stage["UpdateSourceArgs"])[0]
                self.assertEqual(base64.b64decode(payload),
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

    def write_config(self):
        (self.base / "amp_openstarbound_mods.cfg").write_text(
            "".join(f"{k}={v}\n" for k, v in self.config.items()), encoding="utf-8")

    def run_helper(self, expect_success=True):
        self.write_config()
        if self.suffix == "ps1":
            command = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.helper), "-PreStart"]
        else:
            command = [BASH, str(self.helper), "--prestart"]
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
        result = self.run_helper()
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())
        self.assertIn("Workshop Steam Username", result.stdout + result.stderr)

    def test_missing_workshop_download_passes_explicit_username(self):
        self.install_steamcmd()
        self.config["DownloadMissingWorkshopItems"] = "true"
        self.config["WorkshopSteamUsername"] = "fixture_account"
        (self.instance / "steamcmdplugin.kvp").write_text('SteamWorkshop.WorkshopItemIDs=["123456789"]\n')
        self.run_helper()
        self.assertEqual((self.instance / "steamcmd-args.txt").read_text().splitlines(),
                         ["+login", "fixture_account", "+workshop_download_item", "211820", "123456789", "validate", "+quit"])
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
        result = self.run_helper()
        self.assertFalse((self.instance / "steamcmd-args.txt").exists())
        self.assertIn("Workshop Steam Username", result.stdout + result.stderr)


@unittest.skipUnless(WINDOWS, "PowerShell 5.1 helper targets Windows")
class WindowsHelper(HelperBehavior, unittest.TestCase):
    suffix = "ps1"

    def install_steamcmd(self):
        # Compile a tiny executable so the complete native-process boundary is tested.
        source = r'''using System; using System.IO;
class FakeSteamCmd { static int Main(string[] args) {
 string root = AppDomain.CurrentDomain.BaseDirectory;
 File.WriteAllLines(Path.Combine(root, "steamcmd-args.txt"), args);
 if (args.Length != 7 || args[0] != "+login" || args[1] != "fixture_account") return 2;
 string dir = Path.Combine(root, "openstarbound", "workshop", "123456789");
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
[[ "$#" == 7 && "$1" == +login && "$2" == fixture_account ]] || exit 2
mkdir -p "$root/openstarbound/workshop/123456789"
printf fixture > "$root/openstarbound/workshop/123456789/contents.pak"
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
