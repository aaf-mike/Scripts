<#
.SYNOPSIS
  Extract all PDF URLs from a text file and write them to an output file.

.DESCRIPTION
  Scans input text for HTTP/HTTPS URLs that include .pdf (case-insensitive).
  Supports URLs like:
    https://example.com/file.pdf
    https://example.com/file.pdf?x=1
    https://example.com/file.pdf#section
  Trims common trailing punctuation characters that often follow URLs in prose.

.PARAMETER InputFile
  Path to the input text file.

.PARAMETER OutputFile
  Path to the output file to write the extracted PDF URLs (one per line).

.EXAMPLE
  .\GetURLs.ps1 -InputFile '.\new 2.txt' -OutputFile 'PDFURLs.txt'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$InputFile,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputFile -PathType Leaf)) {
    throw "Input file not found: $InputFile"
}

# Regex: match http/https URL that contains .pdf and may have query/fragment
# Excludes whitespace and common quote/bracket delimiters.
$pattern = '(?i)\bhttps?://[^\s<>"' + "'" + ']+?\.pdf(?:\?[^\s<>"' + "'" + ']*)?(?:#[^\s<>"' + "'" + ']*)?'

# Characters to trim from the END of a matched URL if present in prose.
# Using explicit char literals and ASCII apostrophe to avoid “smart quote” issues.
$trimChars = @(
    '.', ',', ';', ':',
    ')', ']', '}', '>',
    '"', "'", '!'
)

# Read and extract
$found = New-Object System.Collections.Generic.List[string]

Get-Content -LiteralPath $InputFile | ForEach-Object {
    $line = $_
    if ([string]::IsNullOrWhiteSpace($line)) { return }

    foreach ($m in [regex]::Matches($line, $pattern)) {
        $url = $m.Value

        # Trim trailing punctuation safely
        $url = $url.TrimEnd($trimChars)

        if (-not [string]::IsNullOrWhiteSpace($url)) {
            [void]$found.Add($url)
        }
    }
}

# Unique results (case-insensitive) and stable order
$unique = $found | Where-Object { $_ } | Select-Object -Unique

# Ensure output directory exists if a directory is specified
$outDir = Split-Path -Parent -Path $OutputFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Write output (UTF8)
$unique | Set-Content -LiteralPath $OutputFile -Encoding UTF8

Write-Host ("Found {0} PDF URL(s). Wrote to: {1}" -f $unique.Count, $OutputFile)
