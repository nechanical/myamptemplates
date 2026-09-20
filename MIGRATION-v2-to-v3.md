# v2 -> v3 migration

- The old **Managed Mod Staging Preference** setting becomes **Unified Mod Preference**.
- Old `ModLoadOrder` is still read by the helper if the new preference list is empty.
- Existing Workshop behavior is preserved.
- Existing non-`amp_*` files under `server/mods` remain unmanaged and untouched.
- To manage those files, move their source copies into `server/localmods/`.
