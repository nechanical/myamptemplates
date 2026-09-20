# Install OpenStarbound Enhanced into a local AMP installation

This variant intentionally uses a different AMP AppConfigId from CubeCoders' built-in
OpenStarbound template so both can coexist.

Enhanced template AppConfigId:

`43301a68-d134-4ef4-9d7c-e3a9e9ca6779`

## Recommended installation: custom configuration repository

1. Create a Git repository, for example `my-amp-templates`.
2. Copy all files from this package into the repository root.
3. Rename `manifest.example.json` to `manifest.json`.
4. Edit `manifest.json`:
   - set `authors`
   - set `origin` to the repository clone URL
   - set `url` to the repository web URL
5. Commit and push to the `main` branch.
6. In the AMP ADS panel open:
   `Configuration -> Instance Deployment -> Configuration Repositories`
7. Add:
   `YOUR_GITHUB_USER/YOUR_REPOSITORY:main`
8. Click `Fetch Latest`.
9. Hard-refresh the AMP web UI if necessary.
10. Choose `Create Instance`.
11. Select **OpenStarbound Enhanced** rather than the stock **OpenStarbound** entry.
12. Run **Update** before the first start.

## Updating this custom template later

Replace the files in the Git repository, commit/push them, then use **Fetch Latest**
again in ADS. New instances will use the new template revision. Existing instances may
need their Generic-module configuration refreshed/recreated depending on the kind of
template change.

## Do not copy into AMP's program/template cache

Directly editing AMP's installed/community template files is brittle because AMP updates
or template refreshes can replace those files. A custom configuration repository is the
safer supported workflow.
