[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$LoaderPath,
    [string]$CatalogPath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($LoaderPath)) {
    $loaderCandidates = @(
        [System.IO.Path]::Combine($RootPath, 'Map Loaded', 'imaplist.lua'),
        [System.IO.Path]::Combine($RootPath, 'tools', 'imaplist.lua')
    )
    $LoaderPath = $loaderCandidates | Where-Object { [System.IO.File]::Exists($_) } | Select-Object -First 1
}

if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
    $catalogCandidates = @(
        [System.IO.Path]::Combine($RootPath, 'Map Editor', 'IMAP_CATALOG.lua'),
        [System.IO.Path]::Combine($RootPath, 'tools', 'IMAP_CATALOG.lua')
    )
    $CatalogPath = $catalogCandidates | Where-Object { [System.IO.File]::Exists($_) } | Select-Object -First 1
}

foreach ($requiredPath in @($LoaderPath, $CatalogPath)) {
    if ([string]::IsNullOrWhiteSpace($requiredPath) -or -not [System.IO.File]::Exists($requiredPath)) {
        throw "Required input file was not found: $requiredPath"
    }
}

$sharedDirectory = [System.IO.Path]::Combine($RootPath, 'shared')
$outputPath = [System.IO.Path]::Combine($sharedDirectory, 'imapConfig.lua')
$reportPath = [System.IO.Path]::Combine($PSScriptRoot, 'imap_merge_report.md')
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$numberPattern = '[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?'

function Get-LuaFieldValue {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Line,
        [Parameter(Mandatory)] [string]$Field,
        [Parameter(Mandatory)] [string]$ValuePattern
    )

    $pattern = '(?:^|[,\{])\s*' + [regex]::Escape($Field) + '\s*=\s*(' + $ValuePattern + ')'
    $match = [regex]::Match($Line, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function ConvertTo-LuaStringContent {
    param([AllowEmptyString()] [string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
}

# Parse the catalog once and key it by the exact decimal hash for fast lookup.
$catalogLines = [System.IO.File]::ReadAllLines($CatalogPath)
$catalogByHash = @{}
$catalogRecordCount = 0

for ($index = 0; $index -lt $catalogLines.Length; $index++) {
    $line = $catalogLines[$index]
    $hash = Get-LuaFieldValue -Line $line -Field 'dec_hash' -ValuePattern '-?\d+'
    if ($null -eq $hash) { continue }

    $hashnameMatch = [regex]::Match($line, '(?:^|[,\{])\s*hashname\s*=\s*"((?:\\.|[^"\\])*)"')
    $x = Get-LuaFieldValue -Line $line -Field 'x' -ValuePattern $numberPattern
    $y = Get-LuaFieldValue -Line $line -Field 'y' -ValuePattern $numberPattern
    $z = Get-LuaFieldValue -Line $line -Field 'z' -ValuePattern $numberPattern
    $h = Get-LuaFieldValue -Line $line -Field 'h' -ValuePattern $numberPattern

    if (-not $hashnameMatch.Success -or $null -in @($x, $y, $z, $h)) {
        throw "Catalog record is incomplete at line $($index + 1): $line"
    }
    if ($catalogByHash.ContainsKey($hash)) {
        throw "Duplicate catalog hash $hash at line $($index + 1)."
    }

    $catalogByHash[$hash] = [pscustomobject]@{
        Hashname = $hashnameMatch.Groups[1].Value
        Hash = $hash
        X = $x
        Y = $y
        Z = $z
        H = $h
        SourceLine = $index + 1
    }
    $catalogRecordCount++
}

if ($catalogRecordCount -eq 0) {
    throw "No catalog records were parsed from $CatalogPath"
}

# Parse every loader call and key it by source line so its original order survives.
$loaderLines = [System.IO.File]::ReadAllLines($LoaderPath)
$imapByLine = [System.Collections.Generic.SortedDictionary[int, object]]::new()
$loaderPattern = '^\s*(?<comment>--\s*)?(?<action>Request|Remove)Imap\s*\(\s*(?<hash>-?\d+)\s*\)(?<tail>.*)$'

for ($index = 0; $index -lt $loaderLines.Length; $index++) {
    $match = [regex]::Match($loaderLines[$index], $loaderPattern)
    if (-not $match.Success) { continue }

    $tail = $match.Groups['tail'].Value
    $description = ''
    $descriptionMarker = $tail.IndexOf('--', [System.StringComparison]::Ordinal)
    if ($descriptionMarker -ge 0) {
        $description = $tail.Substring($descriptionMarker + 2).Trim()
    }

    $imapByLine.Add($index + 1, [pscustomobject]@{
        SourceLine = $index + 1
        Hash = $match.Groups['hash'].Value
        Default = $match.Groups['comment'].Success
        Enable = $match.Groups['action'].Value -eq 'Request'
        Description = $description
    })
}

if ($imapByLine.Count -eq 0) {
    throw "No RequestImap or RemoveImap calls were parsed from $LoaderPath"
}

# A native iMap is uniquely identified by its hash. When the loader contains
# the same hash more than once, retain only its last occurrence so the final
# catalog matches the last executable setting and remains hash-keyed.
$hashOccurrences = @{}
$lastLineByHash = @{}
$lastActiveLineByHash = @{}
foreach ($pair in $imapByLine.GetEnumerator()) {
    $imap = $pair.Value
    if (-not $hashOccurrences.ContainsKey($imap.Hash)) {
        $hashOccurrences[$imap.Hash] = [System.Collections.Generic.List[int]]::new()
    }
    $hashOccurrences[$imap.Hash].Add($imap.SourceLine)
    $lastLineByHash[$imap.Hash] = $imap.SourceLine
    if (-not $imap.Default) {
        $lastActiveLineByHash[$imap.Hash] = $imap.SourceLine
    }
}

$duplicateHashes = @(
    $hashOccurrences.GetEnumerator() |
        Where-Object { $_.Value.Count -gt 1 } |
        Sort-Object { $_.Value[0] }
)
$retainedLineByHash = @{}
foreach ($hash in $lastLineByHash.Keys) {
    $retainedLineByHash[$hash] = if ($lastActiveLineByHash.ContainsKey($hash)) {
        $lastActiveLineByHash[$hash]
    }
    else {
        $lastLineByHash[$hash]
    }
}

$finalImapByLine = [System.Collections.Generic.SortedDictionary[int, object]]::new()
foreach ($pair in $imapByLine.GetEnumerator()) {
    $imap = $pair.Value
    if ($retainedLineByHash[$imap.Hash] -eq $imap.SourceLine) {
        $finalImapByLine.Add($imap.SourceLine, $imap)
    }
}

$generatedLines = [System.Collections.Generic.List[string]]::new()
$generatedLines.Add('-- Generated by tools/build_imap_config.ps1 from imaplist.lua and IMAP_CATALOG.lua.')
$generatedLines.Add('-- Do not reorder: entries follow imaplist.lua source-line order.')
$generatedLines.Add('IMAP_CATALOG = {')
$generatedLines.Add('')

$missingRecords = [System.Collections.Generic.List[object]]::new()
$defaultCount = 0
$enabledCount = 0
$disabledCount = 0

foreach ($pair in $finalImapByLine.GetEnumerator()) {
    $imap = $pair.Value
    $catalog = $catalogByHash[$imap.Hash]
    if ($null -eq $catalog) {
        $catalog = [pscustomobject]@{
            Hashname = ''
            Hash = $imap.Hash
            X = '0.0'
            Y = '0.0'
            Z = '0.0'
            H = '0.0'
        }
        $missingRecords.Add($imap)
    }

    $defaultText = if ($imap.Default) { 'true' } else { 'false' }
    $enableText = if ($imap.Enable) { 'true' } else { 'false' }
    $generatedLines.Add(
        ('    {{dec_hash={0},default={1},enable={2},coords=vector3({3},{4},{5})}},' -f
            $imap.Hash, $defaultText, $enableText,
            $catalog.X, $catalog.Y, $catalog.Z)
    )

    if ($imap.Default) { $defaultCount++ }
    if ($imap.Enable) { $enabledCount++ } else { $disabledCount++ }
}

$generatedLines.Add('}')
$outputText = [string]::Join("`n", $generatedLines) + "`n"

# Validate count, order, hashes, booleans, and vector3 coordinates against the parsed loader table.
$outputMatches = [regex]::Matches($outputText, 'dec_hash=(-?\d+),default=(true|false),enable=(true|false),coords=vector3\(')
if ($outputMatches.Count -ne $finalImapByLine.Count) {
    throw "Output validation failed: expected $($finalImapByLine.Count) records, found $($outputMatches.Count)."
}

$outputIndex = 0
foreach ($pair in $finalImapByLine.GetEnumerator()) {
    $imap = $pair.Value
    $outputMatch = $outputMatches[$outputIndex]
    $expectedDefault = if ($imap.Default) { 'true' } else { 'false' }
    $expectedEnable = if ($imap.Enable) { 'true' } else { 'false' }
    if ($outputMatch.Groups[1].Value -ne $imap.Hash -or
        $outputMatch.Groups[2].Value -ne $expectedDefault -or
        $outputMatch.Groups[3].Value -ne $expectedEnable) {
        throw "Output validation failed at record $($outputIndex + 1), loader line $($imap.SourceLine)."
    }
    $outputIndex++
}


$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add('# iMap config build report')
$reportLines.Add('')
$reportLines.Add("- Loader input: $LoaderPath")
$reportLines.Add("- Catalog input: $CatalogPath")
$reportLines.Add("- Catalog records parsed: $catalogRecordCount")
$reportLines.Add("- Loader entries parsed: $($imapByLine.Count)")
$reportLines.Add("- Unique records generated: $($finalImapByLine.Count)")
$reportLines.Add("- Earlier duplicate entries removed: $($imapByLine.Count - $finalImapByLine.Count)")
$reportLines.Add("- Commented/default entries: $defaultCount")
$reportLines.Add("- RequestImap/enabled entries: $enabledCount")
$reportLines.Add("- RemoveImap/disabled entries: $disabledCount")
$reportLines.Add("- Loader occurrences missing from catalog: $($missingRecords.Count)")
$reportLines.Add("- Repeated loader hashes: $($duplicateHashes.Count)")
$reportLines.Add('')
$reportLines.Add('Rules: commented calls set `default=true`; active calls set `default=false`; RequestImap sets `enable=true`; RemoveImap sets `enable=false`.')
$reportLines.Add('')
$reportLines.Add('## Missing catalog records')
$reportLines.Add('')
$reportLines.Add('These entries were retained with an empty hashname and 0.0 coordinates.')
$reportLines.Add('')
$reportLines.Add('| Hash | Loader line | Description |')
$reportLines.Add('|---:|---:|:---|')
foreach ($imap in $missingRecords) {
    $safeDescription = $imap.Description.Replace('|', '\|')
    $reportLines.Add("| $($imap.Hash) | $($imap.SourceLine) | $safeDescription |")
}
$reportLines.Add('')
$reportLines.Add('## Repeated loader hashes')
$reportLines.Add('')
$reportLines.Add('The last active occurrence is generated. If every occurrence is commented, the last commented occurrence is generated.')
$reportLines.Add('')
$reportLines.Add('| Hash | Loader lines |')
$reportLines.Add('|---:|:---|')
foreach ($duplicate in $duplicateHashes) {
    $reportLines.Add("| $($duplicate.Key) | $([string]::Join(', ', $duplicate.Value)) |")
}

[System.IO.Directory]::CreateDirectory($sharedDirectory) | Out-Null
[System.IO.File]::WriteAllText($outputPath, $outputText, $utf8NoBom)
# [System.IO.File]::WriteAllText($reportPath, ([string]::Join("`n", $reportLines) + "`n"), $utf8NoBom)

Write-Output "Generated: $outputPath"
# Write-Output "Report:    $reportPath"
Write-Output "Records:   $($finalImapByLine.Count) unique from $($imapByLine.Count) loader entries ($defaultCount default, $enabledCount enabled, $disabledCount disabled)"
Write-Output "Missing:   $($missingRecords.Count) loader occurrences use empty names and 0.0 coordinates"
Write-Output "Repeated:  $($duplicateHashes.Count) hashes; $($imapByLine.Count - $finalImapByLine.Count) earlier entries removed"
