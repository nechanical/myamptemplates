# v3 -> v4 migration

v4 keeps the unified mod manager from v3 and expands/reorganizes the dedicated-server UI.

## New server-side controls

- server tick rate
- network compression
- query enable
- RCON enable and timeout
- asset mismatch policy
- secure teams and secure warps
- team invitation timeout
- client custom-world/subworld permissions
- world-creation notifications
- scripting safety/limits/profiling
- universe reset control

## Removed from the AMP dedicated-server UI

The following shared OpenStarbound configuration keys are client-side preferences and are
no longer shown as server gameplay options:

- clientIPJoinable
- clientP2PJoinable
- tutorialMessages
- interactiveHighlight
- monochromeLighting
- crafting.filterHaveMaterials
- inventory.pickupToActionBar
- discord.activityDetails
- clearPlayerFiles
- playerBackupFileCount

Existing values in an already-running `starbound_server.config` are harmless and do not
need to be manually removed.

## Manual/expert settings

`serverUsers` remains editable directly in `storage/starbound_server.config` because it is
a structured JSON object. `serverOverrideAssetsDigest` also remains manual so AMP does not
accidentally convert JSON null into an empty-string digest override.
