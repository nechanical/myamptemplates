# AMP Templates

Custom CubeCoders AMP Generic-module templates maintained in this repository.

## Included templates

- **Garry's Mod Enhanced** — expanded GMod server management with Workshop/client content handling, local resources, mounted Source content, networking, performance, logging/SourceTV, and safe advanced overrides. See [GARRYSMOD-ENHANCED.md](GARRYSMOD-ENHANCED.md).
- **OpenStarbound** — expanded OpenStarbound server management with unified Workshop/local mod handling and extended server/gameplay controls.

---

## OpenStarbound AMP Template — Expanded Server + Unified Mod Manager (v4.3)

This custom CubeCoders AMP Generic Module template extends OpenStarbound with a unified
server-side mod workflow for both Steam Workshop and non-Workshop mods.


## Windows installation/update repair

v4.1 fixes the Windows update failure where AMP could stop at **packed.pak Asset Copy**
with an error similar to:

`Could not find a part of the path ...\\openstarbound\\server\\assets\\packed.pak`

The current OpenStarbound Windows server ZIP contains a top-level
`server_distribution` directory. The template now normalizes that archive after
extraction by moving its contents into AMP's expected server base directory, verifies
that `win\\starbound_server.exe` exists, and explicitly creates the `assets`
directory before copying Starbound's required `packed.pak`.

For an existing instance that hit this error:

1. In ADS, go to **Configuration -> Instance Deployment -> Configuration Repositories** and click **Fetch Latest**.
2. Return to the ADS instance list, right-click the existing OpenStarbound Enhanced instance, and choose **Refresh Configuration**.
3. Manage the instance and run **Update** again.
4. Confirm the update log now says **Install packed.pak** rather than the obsolete **packed.pak Asset Copy** stage.
5. The repair stages are safe to rerun and also handle an already-normalized layout.



### v4.3 default-config 404 repair

The initial server config no longer uses the external
`https://cdn-repo.c7rs.com/AMPTemplates/openstarbound_server.cfg` fetch, which can
return HTTP 404.

The template now embeds its own `starbound_server.config` and creates it only when
`storage/starbound_server.config` does not already exist. Existing server
configuration is preserved on Update.

### v4.2 packed.pak / SteamCMD repair

The Starbound dependency stage now mirrors AMP's stock Starbound template by passing
`UpdateSourceArgs: 211820` as well as `UpdateSourceData: 211820`.

The old generic `CopyFilePath` stage for `packed.pak` has also been replaced with
platform-specific validated copy commands. Those commands:

- verify `{{$FullRootDir}}211820/assets/packed.pak` exists;
- create the OpenStarbound `assets` directory themselves;
- copy `packed.pak` into the OpenStarbound server;
- verify the destination exists afterward; and
- report the missing **source** path explicitly when SteamCMD did not download Starbound.

This makes the error distinguishable from a broken OpenStarbound destination layout.


## What v3 adds

- AMP-native individual Steam Workshop item support.
- Steam Workshop collection expansion.
- A persistent local/private mod source directory.
- Auto-enable or allowlist-based local mod selection.
- A local mod disable list.
- One preference list spanning Workshop and local mods.
- Safe staging that never edits the original local mod source.
- Pre-start synchronization.
- A detailed mod report with missing/invalid sources, unmanaged mods and readable
  local `_metadata` diagnostics.


## Expanded server and gameplay controls

v4 reorganizes the AMP configuration page around settings that the current OpenStarbound
dedicated server actually reads.

### OpenStarbound Server

**General**
- Server Name
- Player Limit

**Performance**
- Server Fidelity: automatic / minimum / low / medium / high
- Server Tick Rate: 5-500 Hz in AMP, default 60 Hz

**Networking**
- AMP-managed game/query ports and bind addresses
- Enable Query Server
- Network Compression: Zstd / None

**Remote Administration**
- Enable RCON Server
- AMP-managed RCON password and port
- RCON Socket Timeout

**Access & Administration**
- Anonymous connections
- Admin commands
- Admin commands from anyone
- Anonymous players as admins
- Banned IPs
- Banned player UUIDs

**Assets & Compatibility**
- Allow Asset Mismatch

### OpenStarbound Gameplay

**Teams**
- Maximum Team Size
- Team Invitation Timeout
- Secure Teams

**World & Warp Security**
- Secure Warps

**Client-created Worlds**
- Disallow Client Custom Worlds
- Disallow Client Subworlds
- Allow Client Subworlds On Any World
- Allow Client Subworlds On Current World

**World Notifications**
- Notify Admins When Worlds Are Created
- Notify All Clients When Worlds Are Created

### OpenStarbound Advanced

**Persistence & Recovery**
- Clear Universe Files On Start

**Script Runtime**
- Safe Scripts
- Script Recursion Limit
- Script Instruction Limit
- Script Instruction Measure Interval
- Script Profiling

### Settings intentionally not exposed as normal AMP toggles

The upstream shared configuration contains several client-only preferences. They have been
removed from the dedicated-server AMP UI: interactive highlighting, monochrome lighting,
tutorial messages, crafting-menu filters, pickup-to-action-bar, Discord activity, client
IP/P2P joinability, player-file cleanup, and player backup count.

`serverUsers` is also left to direct JSON editing because it is a structured object rather
than a scalar/list setting. `serverOverrideAssetsDigest` is left as an expert-only manual
configuration value because an empty string is not equivalent to its normal JSON `null`
state and can produce an invalid digest override.


## Local / non-Workshop mods

The default source directory is:

`openstarbound/server/localmods/`

Put any of the following at the top level:

- `MyMod.pak`
- an unpacked mod directory containing `_metadata`
- a release directory containing one or more `.pak` files (up to two levels deep)

Examples:

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

This makes downloaded GitHub releases, private mods and hand-installed `.pak` files
manageable without mixing the source copies with OpenStarbound's live `mods` directory.

### Enable / disable

By default, **Auto Enable Local Mods** is on. Every valid local source is enabled unless
its exact source name appears under **Disabled Local Mods**.

If you turn Auto Enable off, only names listed under **Managed Local Mods** are enabled.

Source files are never deleted when you disable them.

## Workshop mods

For individual Workshop items, use AMP's normal:

`Configuration -> Updates -> Steam Workshop Items`

For collections, use:

`Configuration -> OpenStarbound Mods -> Steam Workshop Collection IDs`

Collection membership is resolved through Steam and cached so an already-resolved
collection can still be staged if Steam's collection endpoint is temporarily unavailable.

## Unified preference list

Use:

`Configuration -> OpenStarbound Mods -> Unified Mod Preference`

Supported entries:

```text
local:MyCoreFramework.pak
ws:729480149
local:MyPrivateWeapons.pak
1234567890
MyBalancePatch
```

Rules:

- `ws:123456789` = Workshop item.
- a bare numeric value = Workshop item.
- `local:Name` = local source.
- any other bare value = local source name.

Configured sources omitted from the preference list are appended automatically:
Workshop IDs numerically, then local sources alphabetically.

AMP stages the example roughly as:

```text
server/mods/
├── amp_0001_local_MyCoreFramework.pak
├── amp_0002_ws_729480149.pak
├── amp_0003_local_MyPrivateWeapons.pak
├── amp_0004_ws_1234567890.pak
└── amp_0005_local_MyBalancePatch/
```

The originals remain under `localmods/` or AMP's Workshop storage.

## OpenStarbound ordering semantics

The `amp_####` sequence gives deterministic staging/fallback ordering, but OpenStarbound
then evaluates asset-source metadata including:

- `priority`
- `name`
- `requires`
- `includes`

The helper intentionally does not rewrite mod metadata or packed `.pak` files. Doing so
could alter asset digests and cause client/server compatibility problems.

For unpacked local mods, the report reads `_metadata` and identifies duplicate readable
metadata names plus dependency notes. Packed `.pak` files are not automatically unpacked
on every server start, so their metadata is not introspected by the helper.

## Existing manually installed mods

Anything already in:

`openstarbound/server/mods/`

that does **not** start with `amp_` is considered unmanaged and is left untouched.

To bring one under AMP management:

1. Stop the server.
2. Move the `.pak` or unpacked mod directory from `server/mods/` to `server/localmods/`.
3. Start the server or run Update.
4. The helper stages it back into `server/mods/` with an `amp_` prefix.

## Diagnostic report

After Update or server start, inspect:

`openstarbound/server/storage/amp_mods_report.txt`

It records:

- AMP Workshop IDs
- collection IDs and resolved members
- discovered/enabled/disabled local sources
- invalid local entries
- requested unified preference
- unknown preference entries
- effective staging sequence
- successfully staged sources
- missing sources
- unmanaged existing `server/mods` entries
- duplicate readable local metadata names
- readable local dependency/priority notes

## Safety model

Only entries beginning with `amp_` in `server/mods/` are automatically pruned/rebuilt.
The helper does not delete:

- local source mods under `localmods/`
- manually managed non-`amp_` entries in `server/mods/`
- Workshop source downloads

The Local Mods Directory must be relative to the OpenStarbound server directory;
absolute paths and `..` traversal are rejected.

## Automatic synchronization

Synchronization runs:

- at the end of an AMP Update; and
- immediately before the server starts.

Human-readable helpers are included as:

- `openstarboundmanagemods.sh`
- `openstarboundmanagemods.ps1`

They are also embedded into the AMP update stages, so the custom template does not depend
on an externally hosted helper script.

## Ports

- 21025 TCP/UDP — game + query
- 21026 TCP/UDP — RCON

## Attribution

The base configuration is derived from `CubeCoders/AMPTemplates` and retains the
CubeCoders MIT license in `LICENSE-CubeCoders`.
