# AMP Templates

Custom CubeCoders AMP templates that install alongside AMP's built-in ones rather than
replacing them.

- **[Garry's Mod Enhanced](GARRYSMOD-ENHANCED.md)** adds Workshop and client content handling,
  local resources, mounted Source content, and expanded networking, performance and logging
  settings.
- **[OpenStarbound Enhanced](#openstarbound-enhanced)** adds more server and gameplay settings,
  plus a mod manager that loads Steam Workshop items, Workshop collections and local mods in a
  single order.

## Installation

1. In ADS, open `Configuration -> Instance Deployment -> Configuration Repositories`.
2. Add `nechanical/myamptemplates:main` and click **Fetch Latest**, then hard-refresh the web UI
   if the templates don't appear.
3. Click **Create Instance** and choose **Garry's Mod Enhanced** or **OpenStarbound Enhanced**
   instead of the stock entry for the same game.
4. Run **Update** once before starting the server for the first time.

To host your own copy of the templates, see [INSTALL-LOCAL-AMP.md](INSTALL-LOCAL-AMP.md).

### Updating an existing instance

New instances use the latest template as soon as it is fetched, but an existing instance keeps
its old configuration until you refresh it.

1. In `Configuration -> Instance Deployment -> Configuration Repositories`, click
   **Fetch Latest**.
2. In the ADS instance list, right-click the instance and choose **Refresh Configuration**.
3. Manage the instance and run **Update**.

## OpenStarbound Enhanced

### Ports

| Port  | Protocol | Use            |
| ----- | -------- | -------------- |
| 21025 | TCP/UDP  | Game and query |
| 21026 | TCP/UDP  | RCON           |

### Server settings

Server, gameplay and advanced options are on the instance's Configuration page under
**OpenStarbound Server**, **OpenStarbound Gameplay** and **OpenStarbound Advanced**. Named
server accounts (`serverUsers`) aren't available there, so edit them directly in
`openstarbound/server/storage/starbound_server.config`.

### Mods

Mod options live under **Configuration -> OpenStarbound Mods**, and **Enable Unified Mod
Manager** turns the whole system on or off. The mod manager runs at the end of every Update and
again just before the server starts, staging each enabled mod into
`openstarbound/server/mods/` with an `amp_` prefix that sets its load order.

#### Workshop mods

Add individual items where AMP normally expects them, in
`Configuration -> Updates -> Steam Workshop Items`. Add whole collections under **Steam
Workshop Collection IDs**. A collection's contents are cached once resolved, so it still loads
if Steam's collection service is temporarily down. Lookups are batched in groups of up to 50;
each collection keeps its own cache and failure status. A successful empty collection clears
its previous membership, including when that empty cache is later used offline.
Linux collection support requires `jq`, included automatically for AMP containers; install
`jq` on non-container hosts before configuring collections.

With **Download Missing Workshop Items**
enabled, any configured item that isn't on disk yet, which is common for items that only come
from a collection, is downloaded through SteamCMD using AMP's saved Steam login. Existing
item directories without usable `.pak` files or root `_metadata` are also retried once.

**Workshop Download Timeout** bounds each automatic download to 900 seconds (15 minutes) by
default. Increase it for large mods or slow connections. SteamCMD runs without password
prompts or inherited input; its output is shown in the console. On Windows the helper also
prints a status message every 30 seconds while waiting. A timeout terminates the download's
process tree, records the failure, and stops synchronization. Linux automatic downloads use
GNU `timeout` from `coreutils`, included in the container package list.

The helper keeps the SteamCMD executable and its login cache together, including AMP's shared
`Steam` installation in the service user's profile. Starbound's download manifest identifies
the account and launcher used by AMP; otherwise, a single cached account is selected, with the
most recently updated cache preferred when several copies contain that account. A stale local
SteamCMD copy no longer takes precedence over the authenticated installation. The selected
executable path appears in the console for troubleshooting.

Leave **Workshop Steam Username** blank for automatic selection. If the cached accounts remain
ambiguous, set it to the account already authenticated through AMP. The helper selects that
account's installation and runs from its directory, reusing SteamCMD's token in place. It never
copies login tokens or requests another password or Steam Guard code. Steam can still reject
an expired or revoked token; that failure remains visible and stops synchronization.

“Missing” means the item has no usable files in the local download locations; it does not
mean that the public Workshop page was removed. The helper also checks the SteamCMD
executable's own `steamapps/workshop/content/211820/` library. If synchronization stops at
**Downloading locally missing Workshop item**, check the SteamCMD output for login or download
errors, authenticate through AMP again when required, and rerun Update. A successful exit
without usable local assets also fails synchronization rather than starting without the mod.

#### Local mods

Put private mods, GitHub releases and other non-Workshop mods in
`openstarbound/server/localmods/`. Each top-level entry can be a `.pak` file, an unpacked mod
folder containing `_metadata`, or a folder with `.pak` files up to two levels down.

```text
server/
├── localmods/
│   ├── MyPrivateWeapons.pak
│   ├── MyBalancePatch/
│   │   ├── _metadata
│   │   └── ...
│   └── SomeGitHubRelease/
│       └── contents.pak
└── mods/
```

Every local mod is enabled by default, and you can turn one off by adding its exact file or
folder name to **Disabled Local Mods**. If you would rather opt in, switch off **Auto Enable
Local Mods** and list the mods you want under **Managed Local Mods**. Disabling a mod never
deletes its source.

**Local Mods Directory** can point to a different folder, as long as it is a relative path
inside the server folder with no `..`. It must not overlap `server/mods/` or an ancestor of
that directory. On Windows, source paths through junctions or symbolic links are rejected.

#### Load order

**Mod Load Order** sets one order across Workshop and local mods, with one entry per
line.

```text
local:MyCoreFramework.pak
ws:729480149
local:MyPrivateWeapons.pak
1234567890
MyBalancePatch
```

A bare number or `ws:<id>` refers to a Workshop item, while `local:<name>` or any other name
refers to a local mod. Enabled mods you leave out are appended afterward, Workshop items in ID
order and then local mods alphabetically. The list above is staged as follows.

```text
server/mods/
├── amp_0001_local_MyCoreFramework.pak
├── amp_0002_ws_729480149.pak
├── amp_0003_local_MyPrivateWeapons.pak
├── amp_0004_ws_1234567890.pak
└── amp_0005_local_MyBalancePatch/
```

OpenStarbound still applies each mod's own `priority`, `requires` and `includes` metadata on top
of this order. The mod manager never edits mod files, since doing so would change asset digests
and break client compatibility.

#### Mods already in server/mods

Anything in `openstarbound/server/mods/` without the `amp_` prefix is left untouched. To hand
one over to the mod manager, stop the server, move it into `localmods/`, and then start the
server or run Update.

The helper always rebuilds its generated `amp_####_local_*` and `amp_####_ws_*` staging entries,
including old names left by disabled mods or load-order changes. **Prune Previously Managed
Staging** additionally removes other `amp_` entries. Switching pruning off preserves those
unrecognized entries; it does not keep disabled managed mods active. Files in `localmods/`,
unprefixed mods in `server/mods/` and AMP's Workshop downloads are never deleted.

#### Troubleshooting

Each sync writes a report to `openstarbound/server/storage/amp_mods_report.txt`. It shows the
resolved collections, which local mods were enabled or disabled, the final load order, and any
missing, invalid or unrecognized entries in your settings, along with duplicate names and
dependency notes read from unpacked local mods.

Filesystem failures while staging are recorded under **STAGING FAILURES** and stop Update or
pre-start with a nonzero result. Fix the reported filesystem problem and rerun Update before
starting. Automatic download failures are listed under **WORKSHOP DOWNLOAD FAILURES** and also
stop synchronization. Missing sources when automatic downloads are disabled, or unresolved
collections, remain warnings; a failed collection uses its last cached membership when available.

## Development checks

Run `python -m unittest discover -s tests -p "test_*.py" -v`. On Windows, this exercises
PowerShell 5.1 and Git Bash; on Linux it exercises native Bash. The suite uses disposable
instance trees and a local SteamCMD double, without contacting Steam or starting a game.
Download tests use real subprocesses to check output, closed stdin, deadlines and descendant
cleanup. Authentication regressions use isolated profiles and multiple SteamCMD copies to check
cache pairing, manifest account/launcher selection, and unchanged credential files. These doubles
do not verify a live Steam login. Linux/Git Bash download tests require GNU `timeout` from `coreutils`.
Collection regressions require `jq` on PATH, including when using Git Bash on Windows, and
replace HTTP requests with local fixtures while running the real JSON parser.
Linux archive extraction requires `lzip` (automatically included for AMP containers); install
the same package on non-container hosts. That regression is skipped when `lzip` is unavailable.
The existing parser tests also run with
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/openstarboundmanagemods.Tests.ps1`.

After editing either helper or `openstarbound_server.config`, run
`python scripts/sync_embedded_helpers.py` to regenerate the installation payloads. Tests verify
that the embedded bytes match their standalone sources after decoding. The Windows helper
payload is gzip-compressed to fit the Windows command-line limit.

## License

Based on [CubeCoders/AMPTemplates](https://github.com/CubeCoders/AMPTemplates), with the
CubeCoders MIT license retained in [LICENSE-CubeCoders](LICENSE-CubeCoders).
