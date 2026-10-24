# OpenStarbound Enhanced for AMP

A CubeCoders AMP template for running an OpenStarbound dedicated server with more server and
gameplay settings, plus a mod manager that loads Steam Workshop items, Workshop collections and
local mods in a single order. It installs alongside AMP's built-in OpenStarbound template
rather than replacing it.

## Installation

1. In ADS, open `Configuration -> Instance Deployment -> Configuration Repositories`.
2. Add `nechanical/myamptemplates:main` and click **Fetch Latest**, then hard-refresh the web UI
   if the template doesn't appear.
3. Click **Create Instance** and choose **OpenStarbound Enhanced** instead of the stock
   **OpenStarbound** entry.
4. Run **Update** once before starting the server for the first time.

To host your own copy of the template, see [INSTALL-LOCAL-AMP.md](INSTALL-LOCAL-AMP.md). If you
are upgrading an instance created from an earlier version, read
[MIGRATION-v2-to-v3.md](MIGRATION-v2-to-v3.md) and [MIGRATION-v3-to-v4.md](MIGRATION-v3-to-v4.md).

## Ports

| Port  | Protocol | Use            |
| ----- | -------- | -------------- |
| 21025 | TCP/UDP  | Game and query |
| 21026 | TCP/UDP  | RCON           |

## Server settings

Server, gameplay and advanced options are on the instance's Configuration page under
**OpenStarbound Server**, **OpenStarbound Gameplay** and **OpenStarbound Advanced**. Named
server accounts (`serverUsers`) aren't available there, so edit them directly in
`openstarbound/server/storage/starbound_server.config`.

## Mods

Mod options live under **Configuration -> OpenStarbound Mods**, and **Enable Unified Mod
Manager** turns the whole system on or off. The mod manager runs at the end of every Update and
again just before the server starts, staging each enabled mod into
`openstarbound/server/mods/` with an `amp_` prefix that sets its load order.

### Workshop mods

Add individual items where AMP normally expects them, in
`Configuration -> Updates -> Steam Workshop Items`. Add whole collections under **Steam
Workshop Collection IDs**. A collection's contents are cached once resolved, so it still loads
if Steam's collection service is temporarily down. With **Download Missing Workshop Items**
enabled, any configured item that isn't on disk yet, which is common for items that only come
from a collection, is downloaded through SteamCMD using AMP's saved Steam login.

### Local mods

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
inside the server folder with no `..`.

### Load order

**Unified Mod Preference** sets one order across Workshop and local mods, with one entry per
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

### Mods already in server/mods

Anything in `openstarbound/server/mods/` without the `amp_` prefix is left untouched. To hand
one over to the mod manager, stop the server, move it into `localmods/`, and then start the
server or run Update.

With **Prune Previously Managed Staging** enabled, old `amp_` entries in `server/mods/` are
removed and rebuilt on every sync. Files in `localmods/`, unprefixed mods in `server/mods/` and
AMP's Workshop downloads are never deleted.

### Troubleshooting

Each sync writes a report to `openstarbound/server/storage/amp_mods_report.txt`. It shows the
resolved collections, which local mods were enabled or disabled, the final load order, and any
missing, invalid or unrecognized entries in your settings, along with duplicate names and
dependency notes read from unpacked local mods.

## License

Based on [CubeCoders/AMPTemplates](https://github.com/CubeCoders/AMPTemplates), with the
CubeCoders MIT license retained in [LICENSE-CubeCoders](LICENSE-CubeCoders).
