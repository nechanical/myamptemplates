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
$OrderFile = Join-Path $StorageDir "amp_mods_order.txt"
$SteamAppId = "211820"

New-Item -ItemType Directory -Force -Path $ModDir -ErrorAction Stop | Out-Null
New-Item -ItemType Directory -Force -Path $StorageDir -ErrorAction Stop | Out-Null

function Get-KvpValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    $escaped = [regex]::Escape($Key)
    $matchingLines = @(Get-Content -LiteralPath $Path | Where-Object { $_ -match "^\s*$escaped\s*=" })
    if ($matchingLines.Count -eq 0) { return "" }
    return (($matchingLines[-1] -split "=", 2)[1]).Trim()
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

function Assert-SafeLocalDirectory {
    $base = [IO.Path]::GetFullPath($BaseDir).TrimEnd('\', '/')
    $mods = [IO.Path]::GetFullPath($ModDir).TrimEnd('\', '/')
    $source = [IO.Path]::GetFullPath($LocalDir).TrimEnd('\', '/')
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if (-not $source.StartsWith($base + '\', $comparison) -or
        $source.Equals($mods, $comparison) -or
        $source.StartsWith($mods + '\', $comparison) -or
        $mods.StartsWith($source + '\', $comparison)) {
        throw 'Local Mods Directory must be inside the server directory and must not overlap server/mods.'
    }
    # PowerShell 5.1 Resolve-Path does not resolve junctions. Reject aliases on
    # either side before any cleanup rather than compare misleading lexical paths.
    $cursor = $source
    while ($cursor -and -not $cursor.Equals($base, $comparison)) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Local Mods Directory must not traverse junctions or symbolic links.'
        }
        $cursor = Split-Path -Parent $cursor
    }
    $item = Get-Item -LiteralPath $ModDir -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'The managed server/mods directory must not be a junction or symbolic link.'
    }
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
$DownloadTimeoutSeconds = 900
$timeoutValue = 0
if ([int]::TryParse((Get-KvpValue $ModCfg 'WorkshopDownloadTimeoutSeconds'), [ref]$timeoutValue) -and
    $timeoutValue -ge 1 -and $timeoutValue -le 86400) { $DownloadTimeoutSeconds = $timeoutValue }
$PruneManaged = Get-Bool (Get-KvpValue $ModCfg "PruneManagedMods") $true
$AutoEnableLocal = Get-Bool (Get-KvpValue $ModCfg "AutoEnableLocalMods") $true
$LocalRel = Get-SafeLocalDir (Get-KvpValue $ModCfg "LocalModsDirectory")
$LocalDir = Join-Path $BaseDir $LocalRel

if (-not $ManagedEnabled) {
    Write-ModLog "Managed mod synchronization is disabled."
    exit 0
}

Assert-SafeLocalDirectory
New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null

# AMP's listfile control reads/writes this file directly. Import the old setting
# only when no file exists; an empty file is an intentional reset to discovery order.
function Assert-PlainOrderFile {
    $entry = Get-Item -LiteralPath $OrderFile -Force -ErrorAction SilentlyContinue
    if ($entry -and ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw 'Mod Staging Preference must be a regular file, not a directory or link.'
    }
}
function Read-OrderText {
    try { return [IO.File]::ReadAllText($OrderFile, [Text.Encoding]::UTF8) }
    catch { throw "Could not read Mod Staging Preference: $($_.Exception.Message)" }
}
Assert-PlainOrderFile
$OrderFileExisted = Test-Path -LiteralPath $OrderFile -PathType Leaf
$OrderFileBefore = $null
if ($OrderFileExisted) {
    $OrderFileBefore = Read-OrderText
    $PreferenceEntries = @($OrderFileBefore -split "\r?\n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

$CollectionItemIds = New-Object System.Collections.Generic.List[string]
$CollectionErrors = New-Object System.Collections.Generic.List[string]

function Resolve-Collection([string]$CollectionId, $Details) {
    $cache = Join-Path $StorageDir "amp_collection_$CollectionId.txt"
    # Missing, duplicate and malformed records are failures, not empty collections.
    $records = @($Details | Where-Object { [string]$_.publishedfileid -eq $CollectionId })
    if ($records.Count -eq 1 -and $records[0].result -eq 1 -and $records[0].children -is [array]) {
        $invalid = @($records[0].children | Where-Object {
            $_.publishedfileid -isnot [string] -or $_.publishedfileid -notmatch '^[0-9]+$'
        })
        if ($invalid.Count -eq 0) {
            $ids = @(
                $records[0].children |
                ForEach-Object { [string]$_.publishedfileid } |
                Where-Object { $_ -ne $CollectionId } |
                Select-Object -Unique
            )
            try {
                # WriteAllText truncates old membership even when the new set is empty.
                [IO.File]::WriteAllText($cache, ($ids -join "`n"), [Text.Encoding]::ASCII)
            } catch {
                Write-ModWarning "Could not cache collection ${CollectionId}: $($_.Exception.Message)"
            }
            return $ids
        }
    }

    if (Test-Path -LiteralPath $cache) {
        Write-ModWarning "Using cached membership for collection $CollectionId."
        return @(Get-Content -LiteralPath $cache | Where-Object { $_ -match '^\d+$' })
    }

    $CollectionErrors.Add($CollectionId)
    Write-ModWarning "Could not resolve collection $CollectionId and no cached membership is available."
    return @()
}

# Bound request size while sharing a single timeout among up to 50 collections.
for ($offset = 0; $offset -lt $CollectionIds.Count; $offset += 50) {
    $batch = @($CollectionIds | Select-Object -Skip $offset -First 50)
    $body = @{ collectioncount = [string]$batch.Count }
    for ($i = 0; $i -lt $batch.Count; $i++) { $body["publishedfileids[$i]"] = $batch[$i] }
    $details = @()
    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/" `
            -Body $body -TimeoutSec 30 -ErrorAction Stop
        if ($response.response.collectiondetails -is [array]) { $details = @($response.response.collectiondetails) }
    } catch {
        Write-ModWarning "Could not refresh collection batch: $($_.Exception.Message)"
    }
    foreach ($cid in $batch) {
        foreach ($id in @(Resolve-Collection $cid $details)) {
            if (-not $CollectionItemIds.Contains($id)) { $CollectionItemIds.Add($id) }
        }
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
    foreach ($steamcmd in @(Get-SteamCmdCandidates)) {
        $candidates += Join-Path (Split-Path -Parent $steamcmd) "steamapps\workshop\content\$SteamAppId\$Id"
    }
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) {
            if ((Test-Path -LiteralPath (Join-Path $p '_metadata') -PathType Leaf) -or
                @(Get-ItemPaks $p).Count -gt 0) { return $p }
        }
    }
    return $null
}

function Get-ItemPaks([string]$Source) {
    Get-ChildItem -LiteralPath $Source -Filter '*.pak' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { (($_.FullName.Substring($Source.Length).TrimStart('\') -split '\\').Count -le 3) } |
        Sort-Object FullName
}

function Get-SteamCmdCandidates {
    $candidates = @(
        (Join-Path $RootDir "steamcmd.exe"),
        (Join-Path $RootDir "steamcmd\steamcmd.exe"),
        (Join-Path $InstanceDir "steamcmd.exe"),
        (Join-Path $InstanceDir "steamcmd\steamcmd.exe"),
        (Join-Path $env:USERPROFILE "Steam\steamcmd.exe")
    )
    if ($env:LOCALAPPDATA) {
        $candidates += Join-Path $env:LOCALAPPDATA 'Steam\steamcmd\steamcmd.exe'
    }
    foreach ($p in @($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { $p }
    }
}

function Get-WorkshopSteamContext {
    $executables = @(Get-SteamCmdCandidates)
    if ($executables.Count -eq 0) {
        Write-ModWarning 'SteamCMD was not found; cannot auto-download Workshop items.'
        return $null
    }
    $username = (Get-KvpValue $ModCfg 'WorkshopSteamUsername').Trim().Trim('"')
    if ($username -and $username -notmatch '^[A-Za-z0-9_]+$') {
        Write-ModWarning 'Workshop Steam Username must contain only letters, numbers, or underscores.'
        return $null
    }
    # The manifest identifies the account AMP used for its successful app update.
    # Only use that identity in a cache belonging to the executable we will launch.
    $owner = ''
    $launcher = ''
    $manifests = @(
        (Join-Path $RootDir "$SteamAppId\steamapps\appmanifest_$SteamAppId.acf"),
        (Join-Path $RootDir "steamapps\appmanifest_$SteamAppId.acf"),
        (Join-Path $BaseDir "steamapps\appmanifest_$SteamAppId.acf")
    )
    $manifestFiles = @($manifests | ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue })
    foreach ($manifest in @($manifestFiles | Sort-Object LastWriteTimeUtc -Descending)) {
        $content = [string](Get-Content -LiteralPath $manifest.FullName -Raw -ErrorAction SilentlyContinue)
        $match = [regex]::Match($content, '"LastOwner"\s*"([1-9][0-9]+)"')
        if ($match.Success) {
            $owner = $match.Groups[1].Value
            $launcher = [regex]::Match($content, '"LauncherPath"\s*"([^"]+)"').Groups[1].Value.Replace('\\', '\')
            break
        }
    }
    $allNames = @()
    $contexts = @(
        foreach ($executable in $executables) {
            $cachePath = Join-Path (Split-Path -Parent $executable) 'config\config.vdf'
            if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { continue }
            $content = [string](Get-Content -LiteralPath $cachePath -Raw -ErrorAction SilentlyContinue)
            $cache = [regex]::Match($content, '"ConnectCache"\s*\{([^{}]*)\}')
            # Read account names only. Tokens stay in SteamCMD's original cache.
            $names = @([regex]::Matches($cache.Groups[1].Value, '"([^"]*)"\s*"[^"]*"') |
                ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -match '^[A-Za-z0-9_]+$' } | Select-Object -Unique)
            $allNames += $names
            $ownerName = ''
            foreach ($account in [regex]::Matches($content, '"([A-Za-z0-9_]+)"\s*\{[^{}]*"SteamID"\s*"([0-9]+)"[^{}]*\}')) {
                if ($owner -and $account.Groups[2].Value -eq $owner) { $ownerName = $account.Groups[1].Value }
            }
            $selected = ''
            if ($username) {
                if ($names -icontains $username -or $ownerName -ieq $username) { $selected = $username }
            } elseif ($ownerName) { $selected = $ownerName }
            elseif ($names.Count -eq 1) { $selected = $names[0] }
            if ($selected) {
                [pscustomobject]@{ Executable = $executable; Username = $selected
                    OwnerMatch = [bool]($ownerName -and $selected -ieq $ownerName)
                    LauncherMatch = [bool]($launcher -and $executable -ieq $launcher)
                    Modified = (Get-Item -LiteralPath $cachePath).LastWriteTimeUtc }
            }
        }
    )
    $ownerContexts = @($contexts | Where-Object OwnerMatch)
    if ($ownerContexts.Count -gt 0) { $contexts = $ownerContexts }
    if ($contexts.Count -gt 0) {
        $identities = @($contexts.Username | Select-Object -Unique)
        if (-not $username -and $ownerContexts.Count -eq 0) { $identities = @($allNames | Select-Object -Unique) }
        if ($identities.Count -eq 1) {
            return ($contexts | Sort-Object LauncherMatch, Modified -Descending | Select-Object -First 1)
        }
    } elseif ($username) {
        # Explicit names still support caches whose format we cannot inspect.
        return [pscustomobject]@{ Executable = $executables[0]; Username = $username }
    }
    Write-ModWarning 'Cannot identify AMP''s cached Steam account unambiguously. Set Workshop Steam Username to the account authenticated in AMP, then rerun Update.'
    return $null
}

function New-WorkshopDownloadJob {
    # PowerShell 5.1 lacks Process.Kill(entireProcessTree), and taskkill may be
    # denied to service accounts. A private kill-on-close job owns this download.
    if (-not ('AmpWorkshopDownloadJob' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class AmpWorkshopDownloadJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    IntPtr handle;
    public AmpWorkshopDownloadJob() {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits();
        limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(limits))) {
            int error = Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error);
        }
    }
    public void Attach(IntPtr process) {
        if (!AssignProcessToJobObject(handle, process)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() {
        if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; }
    }
}
'@
    }
    return [AmpWorkshopDownloadJob]::new()
}

function Download-Item([string]$Id) {
    if (-not $DownloadMissing) { return $false }
    $context = Get-WorkshopSteamContext
    if (-not $context) { return $false }
    $steamcmd = $context.Executable
    $username = $context.Username
    Write-ModLog "Using SteamCMD and its existing login cache: $steamcmd"
    Write-ModLog "Downloading locally missing Workshop item $Id with AMP's cached Steam login (timeout: ${DownloadTimeoutSeconds}s)..."
    $downloadProcess = [Diagnostics.Process]::new()
    $downloadProcess.StartInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $downloadProcess.StartInfo.WorkingDirectory = Split-Path -Parent $steamcmd
    $arguments = @('+@ShutdownOnFailedCommand', '1', '+@NoPromptForPassword', '1', '+login', $username,
        '+workshop_download_item', $SteamAppId, $Id, 'validate', '+quit')
    $quotedArguments = ($arguments | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ' '
    # The wrapper cannot launch SteamCMD until it belongs to the job. This closes
    # the startup race where a bootstrap child could escape ownership.
    $launch = "if ([Console]::ReadLine() -ne 'start') { exit 1 }; & '" + $steamcmd.Replace("'", "''") + "' $quotedArguments; exit `$LASTEXITCODE"
    $encodedLaunch = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    $downloadProcess.StartInfo.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encodedLaunch"
    $downloadProcess.StartInfo.UseShellExecute = $false
    $downloadProcess.StartInfo.CreateNoWindow = $true
    $downloadProcess.StartInfo.RedirectStandardInput = $true
    # Inherit stdout/stderr so output is visible even when this function's return
    # value is captured. Do not pipe native output into the function result.
    $started = $false
    $downloadJob = $null
    try {
        $downloadJob = New-WorkshopDownloadJob
        $started = $downloadProcess.Start()
        $downloadJob.Attach($downloadProcess.Handle)
        $downloadProcess.StandardInput.WriteLine('start')
        $downloadProcess.StandardInput.Close()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $nextProgress = 30
        while (-not $downloadProcess.WaitForExit(1000)) {
            if ($watch.Elapsed.TotalSeconds -ge $DownloadTimeoutSeconds) {
                Write-ModWarning "Workshop item $Id timed out after ${DownloadTimeoutSeconds}s. Reauthenticate Steam through AMP if required, then rerun Update."
                return $false
            }
            if ($watch.Elapsed.TotalSeconds -ge $nextProgress) {
                Write-ModLog "Still waiting for Workshop item $Id ($([int]$watch.Elapsed.TotalSeconds)s elapsed; limit ${DownloadTimeoutSeconds}s)."
                $nextProgress += 30
            }
        }
        if ($downloadProcess.ExitCode -ne 0) {
            Write-ModWarning "SteamCMD failed for Workshop item $Id (exit code $($downloadProcess.ExitCode)). Check the output above; reauthenticate through AMP if required."
            return $false
        }
        return $true
    } catch {
        Write-ModWarning "SteamCMD could not download Workshop item ${Id}: $($_.Exception.Message)"
        return $false
    } finally {
        if ($started) {
            try { $downloadProcess.StandardInput.Close() } catch { }
        }
        if ($downloadJob) { $downloadJob.Dispose() }
        # If assignment failed, the gated wrapper has not started SteamCMD.
        if ($started -and -not $downloadProcess.WaitForExit(5000)) {
            $downloadProcess.Kill()
            [void]$downloadProcess.WaitForExit(5000)
        }
        $downloadProcess.Dispose()
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
    if ($Raw -match '^(?i:ws|workshop):\s*(\d+)$') { $key = "ws:$($Matches[1])" }
    elseif ($Raw -match '^\d+$') { $key = "ws:$Raw" }
    elseif ($Raw -match '^(?i:local):\s*(.+)$') { $key = "local:$($Matches[1].Trim())" }
    else { $key = "local:$Raw" }
    # Windows accepts case-insensitive source references, but persist the actual
    # discovered spelling so aliases cannot stage the same local mod twice.
    if ($Available.ContainsKey($key)) {
        $info = $Available[$key]
        if ($info.Kind -eq 'workshop') { return "ws:$($info.Value)" }
        return "local:$($info.Value)"
    }
    return $key
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

# Preserve saved positions (including temporarily unavailable entries), then append
# newly discovered configured Workshop and enabled local sources. Do this before
# pruning, and stop rather than overwrite edits made while discovery was running.
$SavedOrderKeys = New-Object System.Collections.Generic.List[string]
foreach ($raw in $PreferenceEntries) {
    $key = Normalize-Preference $raw
    if (-not $SavedOrderKeys.Contains($key)) { $SavedOrderKeys.Add($key) }
}
foreach ($key in $OrderedKeys) {
    if (-not $SavedOrderKeys.Contains($key)) { $SavedOrderKeys.Add($key) }
}
foreach ($key in $SavedOrderKeys) {
    if ($key.Contains("`r") -or $key.Contains("`n")) { throw 'Mod Staging Preference entries must fit on one line.' }
}
$orderText = ($SavedOrderKeys -join "`n")
if ($SavedOrderKeys.Count) { $orderText += "`n" }
Assert-PlainOrderFile
$existsNow = Test-Path -LiteralPath $OrderFile -PathType Leaf
if ($existsNow -ne $OrderFileExisted -or
    ($existsNow -and (Read-OrderText) -cne $OrderFileBefore)) {
    throw 'Mod Staging Preference changed during discovery. Rerun Update; the newer edits were preserved.'
}
if (-not $OrderFileExisted -or $orderText -cne $OrderFileBefore) {
    $temporaryOrder = Join-Path $StorageDir ('.amp-order-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $writeErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        [IO.File]::WriteAllText($temporaryOrder, $orderText, [Text.UTF8Encoding]::new($false))
        if ($OrderFileExisted) { [IO.File]::Replace($temporaryOrder, $OrderFile, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporaryOrder, $OrderFile) }
    } catch {
        throw "Could not save Mod Staging Preference: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $writeErrorPreference
        if (Test-Path -LiteralPath $temporaryOrder) { Remove-Item -LiteralPath $temporaryOrder -Force -ErrorAction SilentlyContinue }
    }
}

# Always reconcile this helper's generated names, including disabled/renumbered
# sources from older versions. The prune toggle additionally clears other amp_* entries.
Get-ChildItem -LiteralPath $ModDir -Force -ErrorAction SilentlyContinue |
    Where-Object { ($PruneManaged -and $_.Name -like 'amp_*') -or $_.Name -match '^amp_[0-9]{4,}_(ws|local)_' } |
    Remove-Item -Force -Recurse -ErrorAction Stop

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
        Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw "File staging did not create '$Target'." }
}

function Stage-Directory([string]$Source, [string]$Target) {
    Remove-Item -LiteralPath $Target -Force -Recurse -ErrorAction SilentlyContinue
    try {
        New-Item -ItemType Junction -Path $Target -Target $Source -ErrorAction Stop | Out-Null
    } catch {
        Copy-Item -LiteralPath $Source -Destination $Target -Recurse -Force -ErrorAction Stop
    }
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) { throw "Directory staging did not create '$Target'." }
}

$StagedKeys = New-Object System.Collections.Generic.List[string]
$MissingKeys = New-Object System.Collections.Generic.List[string]
$StagingFailures = New-Object System.Collections.Generic.List[string]
$DownloadFailures = New-Object System.Collections.Generic.List[string]
$index = 0

foreach ($key in $OrderedKeys) {
    $index++
    $info = $Available[$key]
    try {

        if ($info.Kind -eq "workshop") {
            $id = [string]$info.Value
            $src = Find-ItemSource $id
            if (-not $src -and $DownloadMissing) {
                if (Download-Item $id) { $src = Find-ItemSource $id }
                if (-not $src) {
                    $DownloadFailures.Add($key)
                    Write-ModWarning "Workshop download $id did not produce usable local assets. See SteamCMD output above and rerun Update after resolving the failure."
                }
            }
            if (-not $src) {
                $MissingKeys.Add($key)
                Write-ModWarning "Workshop item $id is not available locally."
                continue
            }

            $paks = @(Get-ItemPaks $src)

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
    } catch {
        $StagingFailures.Add($key)
        $MissingKeys.Add($key)
        Write-ModWarning "Could not stage ${key}: $($_.Exception.Message)"
    }
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("OpenStarbound AMP unified mod report")
$lines.Add("Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))")
$lines.Add("Mode: $(if ($PreStart) { 'pre-start' } else { 'update/manual' })")
$lines.Add("")
$lines.Add("LOCAL MOD SOURCE DIRECTORY")
$lines.Add("  $LocalDir")
$lines.Add("")
$lines.Add('MOD STAGING PREFERENCE FILE')
$lines.Add("  $OrderFile")
$lines.Add('')
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
    @("STAGING FAILURES", @($StagingFailures)),
    @("WORKSHOP DOWNLOAD FAILURES", @($DownloadFailures)),
    @("UNMANAGED EXISTING server/mods ENTRIES", $UnmanagedExisting),
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

Set-Content -LiteralPath $Report -Value $lines -Encoding UTF8 -ErrorAction Stop
$diagnostics = Join-Path $InstanceDir 'openstarboundmoddiagnostics.ps1'
if (Test-Path -LiteralPath $diagnostics -PathType Leaf) {
    & $diagnostics -BaseDir $BaseDir -ReportPath $Report
} else {
    Add-Content -LiteralPath $Report -Value "`nENGINE LOAD ORDER STATUS`n  UNAVAILABLE: Run Update to install the load-order diagnostics helper." -Encoding UTF8
    Write-ModWarning 'Run Update to install the load-order diagnostics helper.'
}
Write-ModLog "Managed $($StagedKeys.Count) source(s): $($WorkshopIds.Count) Workshop candidate(s), $($EnabledLocalNames.Count) enabled local source(s)."
Write-ModLog "Report: $Report"
Write-ModLog "Mod staging list: $OrderFile ($($SavedOrderKeys.Count) entries; saved positions preserved)."
if (($MissingKeys.Count + $MissingLocalNames.Count + $UnknownPreference.Count + $CollectionErrors.Count) -gt 0) {
    Write-ModWarning "One or more configured mod sources/preferences need attention. See the report."
}
if (($StagingFailures.Count + $DownloadFailures.Count) -gt 0) { exit 1 }
exit 0
