# Read-only prediction of OpenStarbound's standard assets/ then mods/ scan.
param([Parameter(Mandatory=$true)][string]$BaseDir,
      [Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference = 'Stop'

function Read-PackedMetadata([string]$Path) {
    # Compile lazily: unreadable/non-pak sources must not require the compiler.
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 8
        if ($stream.Read($header, 0, 8) -ne 8 -or [Text.Encoding]::ASCII.GetString($header) -cne 'SBAsset6') {
            throw 'Unsupported or invalid pak header (expected SBAsset6).'
        }
    } finally { $stream.Dispose() }
    if (-not ('AmpPakMetadata' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public sealed class AmpPakMetadata {
    BinaryReader reader; long limit;
    byte Byte() {
        if (reader.BaseStream.Position >= limit) throw new InvalidDataException("Truncated or oversized metadata (1 MiB limit).");
        return reader.ReadByte();
    }
    ulong Vlq() {
        ulong v=0;
        for (int i=0;i<10;i++) {
            byte b=Byte();
            if (v > (UInt64.MaxValue >> 7)) throw new InvalidDataException("Metadata integer overflow.");
            v=(v<<7)|(uint)(b&127);
            if (b<128) return v;
        }
        throw new InvalidDataException("Invalid metadata integer.");
    }
    int Count() { ulong n=Vlq(); if(n>1048576) throw new InvalidDataException("Oversized metadata value."); return (int)n; }
    string String() {
        int n=Count();
        if(n>limit-reader.BaseStream.Position) throw new InvalidDataException("Truncated metadata string.");
        byte[] b=reader.ReadBytes(n);
        if(b.Length!=n) throw new EndOfStreamException();
        return new UTF8Encoding(false,true).GetString(b);
    }
    Dictionary<string,object> Map(int depth) {
        if(depth>48) throw new InvalidDataException("Metadata nesting exceeds 48 levels.");
        int n=Count(); var result=new Dictionary<string,object>(StringComparer.Ordinal);
        for(int i=0;i<n;i++) { string key=String(); result[key]=Value(depth+1); }
        return result;
    }
    object Value(int depth) {
        if(depth>48) throw new InvalidDataException("Metadata nesting exceeds 48 levels.");
        switch(Byte()) {
            case 1: return null;
            case 2:
                byte[] b=new byte[8]; for(int i=0;i<8;i++) b[i]=Byte();
                if(BitConverter.IsLittleEndian) Array.Reverse(b);
                double d=BitConverter.ToDouble(b,0);
                if(Double.IsNaN(d)||Double.IsInfinity(d)) throw new InvalidDataException("Non-finite metadata number.");
                return d;
            case 3:
                byte flag=Byte(); if(flag>1) throw new InvalidDataException("Invalid metadata boolean.");
                return flag==1;
            case 4:
                ulong u=Vlq(); long half=(long)(u>>1); return (u&1)==0 ? half : -half-1;
            case 5: return String();
            case 6:
                int n=Count(); var a=new List<object>();
                for(int i=0;i<n;i++) a.Add(Value(depth+1)); return a;
            case 7: return Map(depth);
            default: throw new InvalidDataException("Invalid metadata type tag.");
        }
    }
    public static Dictionary<string,object> Read(string path) {
        using(var r=new BinaryReader(File.OpenRead(path))) {
            if(Encoding.ASCII.GetString(r.ReadBytes(8))!="SBAsset6") throw new InvalidDataException("Invalid pak header.");
            ulong offset=0; for(int i=0;i<8;i++) offset=(offset<<8)|r.ReadByte();
            if(offset<16 || offset>(ulong)Math.Max(0,r.BaseStream.Length-6)) throw new InvalidDataException("Invalid pak index offset.");
            r.BaseStream.Position=(long)offset;
            if(Encoding.ASCII.GetString(r.ReadBytes(5))!="INDEX") throw new InvalidDataException("Invalid pak index signature.");
            var p=new AmpPakMetadata {reader=r,limit=Math.Min(r.BaseStream.Length,r.BaseStream.Position+1048576)};
            return p.Map(0);
        }
    }
}
'@
    }
    return ([AmpPakMetadata]::Read($Path) | ConvertTo-Json -Compress -Depth 64 | ConvertFrom-Json)
}

function Compare-EngineString([string]$Left, [string]$Right) {
    # StarString compares UTF-8 bytes. Ordinal UTF-16 differs for astral characters.
    if (-not [regex]::IsMatch($Left+$Right, '[\uD800-\uDFFF]')) {
        return [StringComparer]::Ordinal.Compare($Left,$Right)
    }
    $a=[Text.Encoding]::UTF8.GetBytes($Left); $b=[Text.Encoding]::UTF8.GetBytes($Right)
    for ($i=0;$i -lt [Math]::Min($a.Length,$b.Length);$i++) {
        if ($a[$i] -ne $b[$i]) { return $a[$i].CompareTo($b[$i]) }
    }
    return $a.Length.CompareTo($b.Length)
}

function Format-Value($Value) {
    # Keep each diagnostic on one physical line, including untrusted mod names.
    return ([string]$Value).Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
}

try {
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $duplicates = New-Object 'System.Collections.Generic.List[string]'
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $owners = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $unnamed = New-Object 'System.Collections.Generic.List[object]'
    $managedScan = New-Object 'System.Collections.Generic.List[string]'
    foreach ($directory in @('assets','mods')) {
        $root = Join-Path $BaseDir $directory
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        [string[]]$paths = @(Get-ChildItem -LiteralPath $root -Force | Select-Object -ExpandProperty FullName)
        $scanPaths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($path in $paths) { $scanPaths.Add($path) }
        $scanPaths.Sort([Comparison[string]]{ param($a,$b) Compare-EngineString $a $b })
        foreach ($path in $scanPaths) {
            $file = Get-Item -LiteralPath $path -Force
            if ($file.Name.StartsWith('.') -or $file.Name.StartsWith('_')) { continue }
            if (-not $file.PSIsContainer -and -not $file.Name.EndsWith('.pak',[StringComparison]::Ordinal)) { continue }
            $label = "$directory/$($file.Name)"
            $managed = $label -cmatch '^mods/amp_[0-9]{4,}_(ws|local)_'
            if ($managed) { $managedScan.Add($label) }
            try {
                if ($file.PSIsContainer) {
                    $metaPath = Join-Path $path '_metadata'
                    $meta = if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
                        Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    } else { [pscustomobject]@{} }
                } else { $meta = Read-PackedMetadata $path }
                if ($null -eq $meta -or $meta -isnot [pscustomobject]) { throw 'Metadata must be a JSON object.' }
                $values = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                foreach ($property in $meta.PSObject.Properties) { $values.Add($property.Name,$property.Value) }
                $named = $values.ContainsKey('name')
                if ($named -and $values['name'] -isnot [string]) { throw 'Metadata name must be a string.' }
                $priority = [single]0
                if ($values.ContainsKey('priority')) {
                    if ($values['priority'] -isnot [ValueType] -or $values['priority'] -is [bool]) { throw 'Metadata priority must be numeric.' }
                    $priority = [single]$values['priority']
                    if ([single]::IsNaN($priority) -or [single]::IsInfinity($priority)) { throw 'Metadata priority must be finite.' }
                }
                foreach ($field in @('includes','requires')) {
                    if ($values.ContainsKey($field) -and
                        ($values[$field] -isnot [array] -or @($values[$field] | Where-Object { $_ -isnot [string] }).Count)) {
                        throw "Metadata $field must be an array of strings."
                    }
                }
                $source = [pscustomobject]@{ Path=$label; Name=$(if($named){$values['name']}else{$null}); Named=$named; Priority=$priority;
                    Includes=$(if($values.ContainsKey('includes')){,$values['includes']}else{,@()}); Requires=$(if($values.ContainsKey('requires')){,$values['requires']}else{,@()}); Managed=$managed }
                if ($named) {
                    if ($owners.ContainsKey($source.Name)) {
                        $old = $owners[$source.Name]
                        if ($old.Priority -le $priority) { $owners[$source.Name]=$source; $winner=$source; $loser=$old }
                        else { $winner=$old; $loser=$source }
                        $duplicates.Add("'$($source.Name)' :: selected $($winner.Path) (priority $($winner.Priority)); skipped $($loser.Path) (priority $($loser.Priority))")
                    } else { $owners.Add($source.Name,$source) }
                } else { $unnamed.Add($source) }
            } catch { $issues.Add("$label :: $($_.Exception.Message)") }
        }
    }
    $sources = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in $owners.Values) { $sources.Add($source) }
    foreach ($source in $unnamed) { $sources.Add($source) }
    $sources.Sort([Comparison[object]]{
        param($a,$b)
        $c=$a.Priority.CompareTo($b.Priority)
        if ($c -ne 0) { return $c }
        $aKey=if($a.Named){$a.Name}else{'../'+$a.Path}; $bKey=if($b.Named){$b.Name}else{'../'+$b.Path}
        return (Compare-EngineString $aKey $bKey)
    })
    foreach ($source in $sources) {
        foreach ($req in $source.Requires) {
            if (-not $owners.ContainsKey($req)) { $problems.Add("$($source.Path) :: missing required '$req'") }
        }
    }
    $state = [System.Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    $order = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.List[string]'
    $analysis = @{ Cycle=$false }
    function Visit-Source($Source) {
        if ($state.ContainsKey($Source.Path)) {
            if ($state[$Source.Path] -eq 1) {
                $analysis.Cycle=$true
                $problems.Add('Dependency cycle: '+((@($stack)+$Source.Path) -join ' -> '))
            }
            return
        }
        $state[$Source.Path]=1; $stack.Add($Source.Path)
        foreach ($dep in @($Source.Includes)+@($Source.Requires)) {
            if ($owners.ContainsKey($dep)) { Visit-Source $owners[$dep] }
        }
        $stack.RemoveAt($stack.Count-1); $state[$Source.Path]=2; $order.Add($Source)
    }
    foreach ($source in $sources) { Visit-Source $source }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add(''); $lines.Add('ENGINE LOAD ORDER STATUS')
    if ($issues.Count) { $lines.Add('  INCOMPLETE: unreadable metadata can change source selection and dependency order.') }
    elseif ($problems.Count) { $lines.Add('  INVALID: missing required dependencies or a dependency cycle prevents normal startup.') }
    else { $lines.Add('  COMPLETE: metadata prediction for the standard assets/ then mods/ scan.') }
    $lines.Add('  Custom boot configurations or extra asset sources are outside this prediction. This is not an asset compatibility check.')
    foreach ($section in @(@('SOURCE METADATA ISSUES',$issues),@('DUPLICATE METADATA NAMES',$duplicates),@('DEPENDENCY PROBLEMS',$problems))) {
        $lines.Add(''); $lines.Add($section[0])
        foreach ($value in $section[1]) { $lines.Add('  '+(Format-Value $value)) }
    }
    $lines.Add(''); $lines.Add('PREFERENCE/ENGINE ORDER DIFFERENCES')
    $managedOrder = @($order | Where-Object Managed)
    if (-not $analysis.Cycle) {
        for ($i=0;$i -lt $managedOrder.Count;$i++) {
            $staged = $managedScan.IndexOf($managedOrder[$i].Path)+1
            if ($staged -ne $i+1) { $lines.Add("  $(Format-Value $managedOrder[$i].Path) :: staging position $staged -> engine managed position $($i+1) (metadata priority/name/dependencies)") }
        }
    }
    $lines.Add(''); $lines.Add('PREDICTED ENGINE LOAD ORDER')
    if ($analysis.Cycle) { $lines.Add('  Unavailable until the dependency cycle is resolved.') }
    else {
        $index=0
        foreach ($source in $order) {
            $index++
            $name=if($source.Named){$source.Name | ConvertTo-Json -Compress}else{'<unnamed>'}
            $includes=ConvertTo-Json -InputObject @($source.Includes) -Compress
            $requires=ConvertTo-Json -InputObject @($source.Requires) -Compress
            $lines.Add(('  {0:D4} :: {1} :: name={2} priority={3} includes={4} requires={5}' -f $index,(Format-Value $source.Path),$name,$source.Priority.ToString('R',[Globalization.CultureInfo]::InvariantCulture),$includes,$requires))
        }
    }
    $lines.Add('')
    [IO.File]::AppendAllLines($ReportPath,$lines,[Text.UTF8Encoding]::new($false))
    if ($issues.Count+$duplicates.Count+$problems.Count -gt 0 -or $lines -match 'staging position') {
        Write-Warning '[OpenStarbound Mods] Load-order diagnostics need attention. See amp_mods_report.txt.'
    }
} catch {
    [IO.File]::AppendAllText($ReportPath,"`nENGINE LOAD ORDER STATUS`n  UNAVAILABLE: $(Format-Value $_.Exception.Message)`n",[Text.UTF8Encoding]::new($false))
    Write-Warning '[OpenStarbound Mods] Could not complete load-order diagnostics. See amp_mods_report.txt.'
}
