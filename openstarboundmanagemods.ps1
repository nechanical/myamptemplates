param(
    [switch]$PreStart
)

$ErrorActionPreference = "Continue"

function Write-ModLog([string]$Message) { Write-Host "[OpenStarbound Mods] $Message" }
function Write-ModWarning([string]$Message) { Write-Warning "[OpenStarbound Mods] $Message" }

$InstanceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Join-Path $InstanceDir "openstarbound"
$BaseDir = Join-Path $RootDir "server"
$ModDir = Join-Path $BaseDir "mods"
$StorageDir = Join-Path $BaseDir "storage"
$ModCfg = Join-Path $BaseDir "amp_openstarbound_mods.cfg"
$AmpSteamCfg = Join-Path $InstanceDir "steamcmdplugin.kvp"
$Report = Join-Path $StorageDir "amp_mods_report.txt"
$SteamAppId = "211820"

New-Item -ItemType Directory -Force -Path $ModDir | Out-Null
New-Item -ItemType Directory -Force -Path $StorageDir | Out-Null

function Get-KvpValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $escaped = [regex]::Escape($Key)
    $matches = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^\s*$escaped\s*=" }
    if (-not $matches) { return "" }
    return (($matches[-1] -split "=", 2)[1]).Trim()
}

function Get-ListValues([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $Raw = $Raw.Trim()
    if ($Raw.StartsWith("[")) {
        try {
            $parsed = $Raw | ConvertFrom-Json
            return @($parsed | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        } catch {}
    }
    return @(
        ($Raw -split "[,;]") |
        ForEach-Object { $_.Trim().Trim('"') } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-Ids([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @([regex]::Matches($Text, "\d{6,}") | ForEach-Object { $_.Value } | Select-Object -Unique)
}

function Get-Bool([string]$Raw, [bool]$Fallback) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $Fallback }
    switch -Regex ($Raw.Trim().Trim('"').ToLowerInvariant()) {
        '^(true|1|yes|on)$'  { return $true }
        '^(false|0|no|off)$' { return $false }
        default               { return $Fallback }
    }
}

function Get-SafeLocalDir([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return "localmods" }
    $Raw = $Raw.Trim().TrimEnd("\","/")
    if ([IO.Path]::IsPathRooted($Raw) -or $Raw.Contains("..")) {
        Write-ModWarning "Rejected unsafe Local Mods Directory '$Raw'; using 'localmods'."
        return "localmods"
    }
    return $Raw
}

function Get-SafeName([string]$Name) {
    $s = [regex]::Replace($Name, '[^A-Za-z0-9._-]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { return "mod" }
    return $s
}

$NativeIds = @(Get-Ids (Get-KvpValue $AmpSteamCfg "SteamWorkshop.WorkshopItemIDs"))
$CollectionIds = @(Get-Ids ((Get-ListValues (Get-KvpValue $ModCfg "WorkshopCollectionIDs")) -join ","))

$PreferenceEntries = @(Get-ListValues (Get-KvpValue $ModCfg "UnifiedModPreference"))
if ($PreferenceEntries.Count -eq 0) {
    $PreferenceEntries = @(Get-ListValues (Get-KvpValue $ModCfg "ModLoadOrder"))
}
$ManagedLocalNames = @(Get-ListValues (Get-KvpValue $ModCfg "ManagedLocalMods"))
$DisabledLocalNames = @(Get-ListValues (Get-KvpValue $ModCfg "DisabledLocalMods"))

$ManagedEnabled = Get-Bool (Get-KvpValue $ModCfg "ManagedModsEnabled") $true
$DownloadMissing = Get-Bool (Get-KvpValue $ModCfg "DownloadMissingWorkshopItems") $true
$PruneManaged = Get-Bool (Get-KvpValue $ModCfg "PruneManagedMods") $true
$AutoEnableLocal = Get-Bool (Get-KvpValue $ModCfg "AutoEnableLocalMods") $true
$LocalRel = Get-SafeLocalDir (Get-KvpValue $ModCfg "LocalModsDirectory")
$LocalDir = Join-Path $BaseDir $LocalRel

New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

if (-not $ManagedEnabled) {
    Write-ModLog "Managed mod synchronization is disabled."
    exit 0
}

$CollectionItemIds = New-Object System.Collections.Generic.List[string]
$CollectionErrors = New-Object System.Collections.Generic.List[string]

function Resolve-Collection([string]$CollectionId) {
    $cache = Join-Path $StorageDir "amp_collection_$CollectionId.txt"
    try {
        $body = @{
            collectioncount = "1"
            "publishedfileids[0]" = $CollectionId
        }
        $response = Invoke-RestMethod `
            -Method Post `
            -Uri "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" `
            -Body $body `
            -TimeoutSec 30

        $ids = @(
            $response.response.collectiondetails[0].children |
            ForEach-Object { [string]$_.publishedfileid } |
            Where-Object { $_ -match '^\d+$' -and $_ -ne $CollectionId } |
            Select-Object -Unique
        )
        if ($ids.Count -gt 0) {
            Set-Content -LiteralPath $cache -Value $ids -Encoding ASCII
            return $ids
        }
    } catch {
        Write-ModWarning "Could not refresh collection $CollectionId: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $cache) {
        Write-ModWarning "Using cached membership for collection $CollectionId."
        return @(Get-Content -LiteralPath $cache | Where-Object { $_ -match '^\d+$' })
    }

    $CollectionErrors.Add($CollectionId)
    return @()
}

foreach ($cid in $CollectionIds) {
    foreach ($id in @(Resolve-Collection $cid)) {
        if (-not $CollectionItemIds.Contains($id)) { $CollectionItemIds.Add($id) }
    }
}

$WorkshopIds = @($NativeIds + @($CollectionItemIds) | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique | Sort-Object { [Int64]$_ })

function Find-ItemSource([string]$Id) {
    $candidates = @(
        (Join-Path $RootDir "workshop\$Id"),
        (Join-Path $RootDir "workshop\content\$SteamAppId\$Id"),
        (Join-Path $RootDir "steamapps\workshop\content\$SteamAppId\$Id"),
        (Join-Path $BaseDir "steamapps\workshop\content\$SteamAppId\$Id"),
        (Join-Path $RootDir "211820\steamapps\workshop\content\$SteamAppId\$Id"),
        (Join-Path $env:USERPROFILE "Steam\steamapps\workshop\content\$SteamAppId\$Id"),
        (Join-Path $env:USERPROFILE ".steam\steam\steamapps\workshop\content\$SteamAppId\$Id")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
    }
    return $null
}

function Find-SteamCmd {
    $candidates = @(
        (Join-Path $RootDir "steamcmd.exe"),
        (Join-Path $RootDir "steamcmd\steamcmd.exe"),
        (Join-Path $InstanceDir "steamcmd.exe"),
        (Join-Path $env:USERPROFILE "Steam\steamcmd.exe")
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
}

function Download-Item([string]$Id) {
    if (-not $DownloadMissing) { return $false }
    $steamcmd = Find-SteamCmd
    if (-not $steamcmd) {
        Write-ModWarning "SteamCMD was not found; cannot auto-download Workshop item $Id."
        return $false
    }
    Write-ModLog "Downloading missing Workshop item $Id with AMP's cached Steam login..."
    try {
        & $steamcmd "+login" "+workshop_download_item" $SteamAppId $Id "validate" "+quit"
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-ModWarning "SteamCMD could not download Workshop item $Id: $($_.Exception.Message)"
        return $false
    }
}

# Discover local/private sources.
$LocalSources = @{}
$InvalidLocalNames = New-Object System.Collections.Generic.List[string]
foreach ($entry in @(Get-ChildItem -LiteralPath $LocalDir -Force -ErrorAction SilentlyContinue)) {
    if ($entry.Name.StartsWith(".") -or $entry.Name.StartsWith("_")) { continue }

    if (-not $entry.PSIsContainer -and $entry.Extension -ieq ".pak") {
        $LocalSources[$entry.Name] = @{ Path = $entry.FullName; Kind = "pak" }
    }
    elseif ($entry.PSIsContainer -and (Test-Path -LiteralPath (Join-Path $entry.FullName "_metadata") -PathType Leaf)) {
        $LocalSources[$entry.Name] = @{ Path = $entry.FullName; Kind = "directory" }
    }
    elseif ($entry.PSIsContainer) {
        $nested = @(Get-ChildItem -LiteralPath $entry.FullName -Filter "*.pak" -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        $relative = $_.FullName.Substring($entry.FullName.Length).TrimStart("\")
                        (($relative -split "\\").Count -le 2)
                    })
        if ($nested.Count -gt 0) {
            $LocalSources[$entry.Name] = @{ Path = $entry.FullName; Kind = "pakbundle" }
        } else {
            $InvalidLocalNames.Add($entry.Name)
        }
    }
    else {
        $InvalidLocalNames.Add($entry.Name)
    }
}

$DiscoveredLocalNames = @($LocalSources.Keys | Sort-Object)
$EnabledLocalNames = New-Object System.Collections.Generic.List[string]
$MissingLocalNames = New-Object System.Collections.Generic.List[string]

if ($AutoEnableLocal) {
    foreach ($name in $DiscoveredLocalNames) {
        if ($DisabledLocalNames -notcontains $name) { $EnabledLocalNames.Add($name) }
    }
} else {
    foreach ($name in $ManagedLocalNames) {
        if ($DisabledLocalNames -contains $name) { continue }
        if ($LocalSources.ContainsKey($name)) { $EnabledLocalNames.Add($name) }
        else { $MissingLocalNames.Add($name) }
    }
}

$Available = @{}
foreach ($id in $WorkshopIds) { $Available["ws:$id"] = @{ Kind = "workshop"; Value = $id } }
foreach ($name in $EnabledLocalNames) { $Available["local:$name"] = @{ Kind = "local"; Value = $name } }

function Normalize-Preference([string]$Raw) {
    $Raw = $Raw.Trim()
    if ($Raw -match '^(?i:ws|workshop):\s*(\d+)$') { return "ws:$($Matches[1])" }
    if ($Raw -match '^\d+$') { return "ws:$Raw" }
    if ($Raw -match '^(?i:local):\s*(.+)$') { return "local:$($Matches[1].Trim())" }
    return "local:$Raw"
}

$OrderedKeys = New-Object System.Collections.Generic.List[string]
$UnknownPreference = New-Object System.Collections.Generic.List[string]
foreach ($raw in $PreferenceEntries) {
    $key = Normalize-Preference $raw
    if ($Available.ContainsKey($key)) {
        if (-not $OrderedKeys.Contains($key)) { $OrderedKeys.Add($key) }
    } else {
        $UnknownPreference.Add($raw)
    }
}
foreach ($id in $WorkshopIds) {
    $key = "ws:$id"
    if (-not $OrderedKeys.Contains($key)) { $OrderedKeys.Add($key) }
}
foreach ($name in $EnabledLocalNames) {
    $key = "local:$name"
    if (-not $OrderedKeys.Contains($key)) { $OrderedKeys.Add($key) }
}

if ($PruneManaged) {
    Get-ChildItem -LiteralPath $ModDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "amp_*" } |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
}

$UnmanagedExisting = @(
    Get-ChildItem -LiteralPath $ModDir -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "amp_*" } |
    Select-Object -ExpandProperty Name |
    Sort-Object
)

function Stage-File([string]$Source, [string]$Target) {
    Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType HardLink -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
}

function Stage-Directory([string]$Source, [string]$Target) {
    Remove-Item -LiteralPath $Target -Force -Recurse -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Junction -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force
    }
}

$StagedKeys = New-Object System.Collections.Generic.List[string]
$MissingKeys = New-Object System.Collections.Generic.List[string]
$index = 0

foreach ($key in $OrderedKeys) {
    $index++
    $info = $Available[$key]

    if ($info.Kind -eq "workshop") {
        $id = [string]$info.Value
        $src = Find-ItemSource $id
        if (-not $src) {
            [void](Download-Item $id)
            $src = Find-ItemSource $id
        }
        if (-not $src) {
            $MissingKeys.Add($key)
            Write-ModWarning "Workshop item $id is not available locally."
            continue
        }

        $paks = @(Get-ChildItem -LiteralPath $src -Filter "*.pak" -File -Recurse -ErrorAction SilentlyContinue |
                  Where-Object {
                      $relative = $_.FullName.Substring($src.Length).TrimStart("\")
                      (($relative -split "\\").Count -le 3)
                  } |
                  Sort-Object FullName)

        if ($paks.Count -gt 0) {
            $n = 0
            foreach ($pak in $paks) {
                $n++
                if ($paks.Count -eq 1) { $name = "amp_{0:D4}_ws_{1}.pak" -f $index, $id }
                else { $name = "amp_{0:D4}_ws_{1}_{2:D2}.pak" -f $index, $id, $n }
                Stage-File $pak.FullName (Join-Path $ModDir $name)
            }
            $StagedKeys.Add($key)
        }
        elseif (Test-Path -LiteralPath (Join-Path $src "_metadata") -PathType Leaf) {
            Stage-Directory $src (Join-Path $ModDir ("amp_{0:D4}_ws_{1}" -f $index, $id))
            $StagedKeys.Add($key)
        }
        else {
            $MissingKeys.Add($key)
            Write-ModWarning "Workshop item $id has no .pak or root _metadata."
        }
        continue
    }

    $name = [string]$info.Value
    if (-not $LocalSources.ContainsKey($name)) {
        $MissingKeys.Add($key)
        continue
    }
    $local = $LocalSources[$name]
    $safe = Get-SafeName $name

    switch ($local.Kind) {
        "pak" {
            $base = [IO.Path]::GetFileNameWithoutExtension($safe)
            Stage-File $local.Path (Join-Path $ModDir ("amp_{0:D4}_local_{1}.pak" -f $index, $base))
            $StagedKeys.Add($key)
        }
        "directory" {
            Stage-Directory $local.Path (Join-Path $ModDir ("amp_{0:D4}_local_{1}" -f $index, $safe))
            $StagedKeys.Add($key)
        }
        "pakbundle" {
            $paks = @(Get-ChildItem -LiteralPath $local.Path -Filter "*.pak" -File -Recurse -ErrorAction SilentlyContinue |
                      Where-Object {
                          $relative = $_.FullName.Substring($local.Path.Length).TrimStart("\")
                          (($relative -split "\\").Count -le 2)
                      } |
                      Sort-Object FullName)
            if ($paks.Count -eq 0) {
                $MissingKeys.Add($key)
            } else {
                $n = 0
                foreach ($pak in $paks) {
                    $n++
                    Stage-File $pak.FullName (Join-Path $ModDir ("amp_{0:D4}_local_{1}_{2:D2}.pak" -f $index, $safe, $n))
                }
                $StagedKeys.Add($key)
            }
        }
    }
}

# Metadata validation for unpacked local mods. Packed mods are not automatically unpacked.
$MetadataOwners = @{}
$DuplicateMetadataNames = New-Object System.Collections.Generic.List[string]
$MetadataNotes = New-Object System.Collections.Generic.List[string]

foreach ($name in $EnabledLocalNames) {
    $info = $LocalSources[$name]
    if ($info.Kind -ne "directory") { continue }
    $metaPath = Join-Path $info.Path "_metadata"
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        $metaName = if ($meta.name) { [string]$meta.name } else { $name }
        if ($MetadataOwners.ContainsKey($metaName)) {
            $DuplicateMetadataNames.Add("$metaName :: $($MetadataOwners[$metaName]) | $name")
        } else {
            $MetadataOwners[$metaName] = $name
        }
    } catch {
        $MetadataNotes.Add("$name :: could not parse _metadata: $($_.Exception.Message)")
    }
}

foreach ($name in $EnabledLocalNames) {
    $info = $LocalSources[$name]
    if ($info.Kind -ne "directory") { continue }
    $metaPath = Join-Path $info.Path "_metadata"
    try {
        $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
        $metaName = if ($meta.name) { [string]$meta.name } else { $name }
        $priority = if ($null -ne $meta.priority) { [string]$meta.priority } else { "0" }
        $MetadataNotes.Add("$name :: name=$metaName priority=$priority")
        foreach ($req in @($meta.requires)) {
            if ($req -and $req -ne "base" -and -not $MetadataOwners.ContainsKey([string]$req)) {
                $MetadataNotes.Add("$name :: requires '$req' (not found among readable unpacked local metadata; it may be supplied by a packed/Workshop mod)")
            }
        }
    } catch {}
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("OpenStarbound AMP unified mod report")
$lines.Add("Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$lines.Add("Mode: $(if ($PreStart) { 'pre-start' } else { 'update/manual' })")
$lines.Add("")
$lines.Add("LOCAL MOD SOURCE DIRECTORY")
$lines.Add("  $LocalDir")
$lines.Add("")
$sections = @(
    @("NATIVE AMP WORKSHOP IDS", $NativeIds),
    @("WORKSHOP COLLECTION IDS", $CollectionIds),
    @("RESOLVED COLLECTION ITEM IDS", @($CollectionItemIds)),
    @("DISCOVERED LOCAL SOURCES", $DiscoveredLocalNames),
    @("ENABLED LOCAL SOURCES", @($EnabledLocalNames)),
    @("DISABLED LOCAL SOURCES", $DisabledLocalNames),
    @("INVALID/UNSUPPORTED LOCAL ENTRIES", @($InvalidLocalNames)),
    @("REQUESTED UNIFIED PREFERENCE", $PreferenceEntries),
    @("UNKNOWN PREFERENCE ENTRIES", @($UnknownPreference)),
    @("EFFECTIVE MANAGED STAGING SEQUENCE", @($OrderedKeys)),
    @("SUCCESSFULLY STAGED", @($StagedKeys)),
    @("MISSING/UNUSABLE MANAGED SOURCES", @($MissingKeys) + @($MissingLocalNames | ForEach-Object { "local:$_" })),
    @("UNMANAGED EXISTING server/mods ENTRIES", $UnmanagedExisting),
    @("DUPLICATE READABLE LOCAL METADATA NAMES", @($DuplicateMetadataNames)),
    @("READABLE LOCAL METADATA NOTES", @($MetadataNotes)),
    @("COLLECTIONS THAT COULD NOT BE RESOLVED", @($CollectionErrors))
)
foreach ($section in $sections) {
    $lines.Add([string]$section[0])
    foreach ($value in @($section[1])) { if ($null -ne $value -and "$value" -ne "") { $lines.Add("  $value") } }
    $lines.Add("")
}
$lines.Add("ORDERING NOTE")
$lines.Add("  amp_#### filenames provide deterministic staging/fallback order.")
$lines.Add("  OpenStarbound ultimately sorts asset sources using mod metadata priority/name")
$lines.Add("  and then dependency metadata (requires/includes). This helper does not rewrite")
$lines.Add("  mod metadata or packed .pak contents, avoiding asset-digest/client mismatches.")
$lines.Add("")
$lines.Add("LOCAL MOD FORMAT")
$lines.Add("  Put .pak files, unpacked mod directories containing _metadata, or release")
$lines.Add("  directories containing .pak files into the local source directory.")

Set-Content -LiteralPath $Report -Value $lines -Encoding UTF8
Write-ModLog "Managed $($StagedKeys.Count) source(s): $($WorkshopIds.Count) Workshop candidate(s), $($EnabledLocalNames.Count) enabled local source(s)."
Write-ModLog "Report: $Report"
if (($MissingKeys.Count + $MissingLocalNames.Count + $UnknownPreference.Count) -gt 0) {
    Write-ModWarning "One or more configured mod sources/preferences need attention. See the report."
}
exit 0
