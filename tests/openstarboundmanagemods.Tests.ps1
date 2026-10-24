# Run with powershell.exe or pwsh -NoProfile -File tests/openstarboundmanagemods.Tests.ps1.
# Only parse the helper and load Get-KvpValue; never execute its installation/mod actions.
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$script:Failures = 0
$script:Checks = 0

function Assert-Check([bool]$Condition, [string]$Name) {
    $script:Checks++
    if ($Condition) {
        Write-Host "PASS: $Name"
    } else {
        $script:Failures++
        Write-Host "FAIL: $Name"
    }
}

$helperPath = Join-Path $RepositoryRoot "openstarboundmanagemods.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $helperPath, [ref]$tokens, [ref]$parseErrors
)
Assert-Check ($parseErrors.Count -eq 0) "Standalone helper parses without errors"
foreach ($parseError in $parseErrors) { Write-Host $parseError.Message }

$updates = Get-Content -LiteralPath (Join-Path $RepositoryRoot "openstarboundupdates.json") -Raw | ConvertFrom-Json
$stages = @($updates | Where-Object {
    $_.UpdateStageName -eq "Install Unified Mod Helper" -and $_.UpdateSourcePlatform -eq "Windows"
})
if ($stages.Count -ne 1) { throw "Expected exactly one Windows helper installation stage." }
$payloadMatch = [regex]::Match($stages[0].UpdateSourceArgs, '\$b=''(?<Payload>[A-Za-z0-9+/=]+)''')
if (-not $payloadMatch.Success) { throw "Could not locate the embedded Windows helper." }
$embeddedBytes = [Convert]::FromBase64String($payloadMatch.Groups["Payload"].Value)
$sourceBytes = [IO.File]::ReadAllBytes($helperPath)
Assert-Check ([Convert]::ToBase64String($embeddedBytes) -ceq [Convert]::ToBase64String($sourceBytes)) "Embedded helper matches standalone bytes exactly"
$embeddedErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput(
    [Text.Encoding]::UTF8.GetString($embeddedBytes), [ref]$tokens, [ref]$embeddedErrors
)
Assert-Check ($embeddedErrors.Count -eq 0) "Embedded helper parses without errors"

# Extract this one function without dot-sourcing the full, side-effecting helper.
$function = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Get-KvpValue"
}, $false)
if ($null -eq $function) { throw "Get-KvpValue was not found." }
. ([scriptblock]::Create($function.Extent.Text))

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("openstarbound-tests-" + [guid]::NewGuid().ToString("N"))
$null = New-Item -ItemType Directory -Path $temporaryDirectory
try {
    $fixturePath = Join-Path $temporaryDirectory "settings.kvp"
    $cases = @(
        @{ Name = "Single matching line"; Lines = @("WorkshopCollectionIDs=123456789"); Key = "WorkshopCollectionIDs"; Expected = "123456789" },
        @{ Name = "Whitespace is trimmed"; Lines = @("  Key  =  value  "); Key = "Key"; Expected = "value" },
        @{ Name = "Duplicate keys use the last line"; Lines = @("Key=first", "Other=ignored", "Key=last"); Key = "Key"; Expected = "last" },
        @{ Name = "Empty value"; Lines = @("Key="); Key = "Key"; Expected = "" },
        @{ Name = "Value containing equals signs"; Lines = @("Key=a=b=c"); Key = "Key"; Expected = "a=b=c" },
        @{ Name = "Missing key"; Lines = @("Other=value"); Key = "Key"; Expected = "" },
        @{ Name = "Empty file"; Lines = @(); Key = "Key"; Expected = "" },
        @{ Name = "Key prefix is not a match"; Lines = @("KeyExtra=ignored", "Key=value"); Key = "Key"; Expected = "value" },
        @{ Name = "Regex characters in key are literal"; Lines = @("A0B1=ignored", "A.B[1]=literal"); Key = "A.B[1]"; Expected = "literal" },
        @{ Name = "Case-insensitive key lookup is preserved"; Lines = @("key=value"); Key = "KEY"; Expected = "value" },
        @{ Name = "False setting stays false"; Lines = @("ManagedModsEnabled=false"); Key = "ManagedModsEnabled"; Expected = "false" }
    )
    foreach ($case in $cases) {
        # Use Windows-style newlines even when the test runs under pwsh on Linux.
        [IO.File]::WriteAllText($fixturePath, ($case.Lines -join "`r`n"))
        try {
            $actual = Get-KvpValue $fixturePath $case.Key
            Assert-Check ($actual -is [string] -and $actual -ceq $case.Expected) $case.Name
        } catch {
            Assert-Check $false ("{0}: {1}" -f $case.Name, $_.Exception.Message)
        }
    }
    $missingPath = Join-Path $temporaryDirectory "missing.kvp"
    Assert-Check ((Get-KvpValue $missingPath "Key") -ceq "") "Missing file"
} finally {
    Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
}

if ($script:Failures -gt 0) {
    throw "$script:Failures of $script:Checks checks failed."
}
Write-Host "All $script:Checks checks passed on PowerShell $($PSVersionTable.PSVersion)."
