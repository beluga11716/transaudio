#requires -Version 5.1
<#
  PowerShell port of translate/po2ymo.py (same YMO binary format), so the
  translations can be rebuilt on a machine without Python/polib.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File po2ymo.ps1 -In source\zh_CN.po -Out generated\zh_CN.ymo
    powershell -NoProfile -ExecutionPolicy Bypass -File po2ymo.ps1 -All
#>
param(
    [string]$In,
    [string]$Out,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Unescape-Po([string]$text) {
    if ($null -eq $text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($c -eq '\' -and $i + 1 -lt $text.Length) {
            $n = $text[$i + 1]
            switch -CaseSensitive ($n) {
                'n' { [void]$sb.Append("`n"); $i++ }
                't' { [void]$sb.Append("`t"); $i++ }
                'r' { [void]$sb.Append("`r"); $i++ }
                '"' { [void]$sb.Append('"'); $i++ }
                '\' { [void]$sb.Append('\'); $i++ }
                default { [void]$sb.Append($c) }
            }
        }
        else {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function Read-PoEntries([string]$path) {
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    $entries = New-Object System.Collections.ArrayList
    $current = $null
    $field = $null

    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*$') {
            if ($null -ne $current -and $current.ContainsKey('msgid')) { [void]$entries.Add($current) }
            $current = $null
            $field = $null
            continue
        }
        if ($line.StartsWith('#')) { continue }

        if ($line -match '^msgid\s+"(.*)"$') {
            if ($null -ne $current -and $current.ContainsKey('msgid')) { [void]$entries.Add($current) }
            $current = @{ msgid = (Unescape-Po $matches[1]); msgstr = '' }
            $field = 'msgid'
            continue
        }
        if ($line -match '^msgstr\s+"(.*)"$') {
            if ($null -eq $current) { $current = @{ msgid = ''; msgstr = '' } }
            $current.msgstr = (Unescape-Po $matches[1])
            $field = 'msgstr'
            continue
        }
        if ($line -match '^"(.*)"$') {
            $value = Unescape-Po $matches[1]
            if ($field -eq 'msgid') { $current.msgid += $value }
            elseif ($field -eq 'msgstr') { $current.msgstr += $value }
            continue
        }
    }
    if ($null -ne $current -and $current.ContainsKey('msgid')) { [void]$entries.Add($current) }
    return $entries
}

function Get-Fnv1a32([byte[]]$bytes) {
    $hash = [uint64]2166136261
    foreach ($b in $bytes) {
        $hash = $hash -bxor [uint64]$b
        $hash = ($hash * [uint64]16777619) % [uint64]4294967296
    }
    return [uint32]$hash
}

function Convert-PoToYmo([string]$inFile, [string]$outFile) {
    $entries = Read-PoEntries $inFile
    $units = New-Object System.Collections.Specialized.OrderedDictionary

    foreach ($entry in $entries) {
        if ([string]::IsNullOrEmpty($entry.msgid)) { continue }
        if ([string]::IsNullOrEmpty($entry.msgstr)) { continue }
        $sourceBytes = [System.Text.Encoding]::Unicode.GetBytes($entry.msgid)
        $hash = Get-Fnv1a32 $sourceBytes
        $data = [System.Text.Encoding]::Unicode.GetBytes($entry.msgstr) + [byte[]](0, 0)
        $units[$hash] = $data
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint16]$units.Count)

    $offset = 2 + $units.Count * 6
    $dataOffset = $offset
    foreach ($hash in $units.Keys) {
        $bw.Write([uint32]$hash)
        $bw.Write([uint16]$dataOffset)
        $dataOffset += $units[$hash].Length
    }
    foreach ($hash in $units.Keys) {
        $bw.Write([byte[]]$units[$hash])
    }
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    [System.IO.File]::WriteAllBytes($outFile, $bytes)
    return $units.Count
}

if ($All) {
    $pairs = @(
        @{ In = Join-Path $here 'source\zh_CN.po'; Out = Join-Path $here 'generated\zh_CN.ymo' },
        @{ In = Join-Path $here 'source\zh_TW.po'; Out = Join-Path $here 'generated\zh_TW.ymo' }
    )
    foreach ($pair in $pairs) {
        $count = Convert-PoToYmo $pair.In $pair.Out
        "wrote $($pair.Out) ($count strings)"
    }

    $rc = Join-Path $here 'generated\translate.rc'
    $rcText = @(
        '#include "../../targetver.h"',
        '#include "windows.h"',
        'LANGUAGE LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED',
        '1 YMO "zh_CN.ymo"',
        'LANGUAGE LANG_CHINESE, SUBLANG_CHINESE_TRADITIONAL',
        '1 YMO "zh_TW.ymo"'
    ) -join "`r`n"
    # .gitattributes stores *.rc as UTF-16LE-BOM with CRLF in the working tree,
    # so the generated file has to be written with the same encoding.
    [System.IO.File]::WriteAllText($rc, $rcText + "`r`n", (New-Object System.Text.UnicodeEncoding $false, $true))
    "wrote $rc"
}
else {
    if (-not $In -or -not $Out) { throw 'use -In <po> -Out <ymo>, or -All' }
    $count = Convert-PoToYmo $In $Out
    "wrote $Out ($count strings)"
}
