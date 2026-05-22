Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------
# CONFIGURATION (edit here)
# ---------------------------

$DefaultUrlFileName          = 'urls.txt'
$DefaultOutputFileName       = 'urls.about.txt'

# If $true, overwrite the selected input URL file rather than creating a separate output file.
$ReplaceInputFile            = $true

# If $ReplaceInputFile = $false and output exists, back it up (rename) before writing the new output.
$BackupOutputIfExists        = $true

# Backup naming nicety:
#  - $true  => urls.txt -> urls.bak, urls.bak1, ...
#  - $false => urls.txt -> urls.txt.bak, urls.txt.bak1, ...
$BackupDropExtension         = $true

# How many backups to keep. Default 5. Set to 0 to keep all backups.
$MaxBackupsToKeep            = 5

# About prefix line
$AboutPrefix                 = '# About: '

# About refresh mode:
#  1 = NoAction       (do not fetch; keep existing Abouts; sanitize; update timestamp only if missing/changed by sanitization)
#  2 = DeleteOnly     (remove Abouts; do not fetch)
#  3 = CheckAndUpdate (fetch; update About only if changed; timestamp becomes repo last-updated time)
$AboutRefreshMode            = 3

# URL indentation control:
#  - If $false: normalize URLs to exactly 4 leading spaces
#  - If $true : remove indentation (no leading spaces) and keep removed
$RemoveUrlIndentation        = $false
$UrlIndent                   = '    '   # used only when $RemoveUrlIndentation = $false

# Network timeouts
$TimeoutSec                  = 30        # per-request timeout (seconds)
$HardHangSec                 = 60        # parent polling "hang" threshold (seconds) - should be > TimeoutSec

# HTTP output text
$NotFoundText                = '[NOT FOUND]'                 # ALL CAPS per request (404)
$RateLimitedText             = '[RATE LIMITED (HTTP 429)]'
$AboutNotFoundText           = '[ABOUT NOT FOUND]'

# 429 retry/backoff
$Max429Retries               = 2
$DefaultRetryAfterSec        = 30

# Parallel throttling (RunspacePool-based; works in PS7 & PS5.1)
$EnableSmartParallel         = $true
$StartSmartThrottle          = 1
$MaxSmartThrottle            = 12
$SmartSampleSize             = 10

# If smart parallel disabled, use this throttle:
$FixedThrottle               = 4

# Progress / output behavior
$ShowProgress                = $true
$ForceVerboseIfNoProgress    = $true
$VerboseEveryNCompletions    = 10

# Content rules
$RemoveOrphanAboutLines      = $true
$StripTrailingTextAfterUrl   = $false

# Timestamp formatting for About updates (this will represent repo last-updated time in mode 3)
$AboutTimestampFormat        = 'MM/dd/yyyy - HH:mm'

# ---------------------------
# END CONFIGURATION
# ---------------------------


# ---------------------------
# Force ProgressPreference to Continue, restore at end
# ---------------------------
$__OriginalProgressPreference = $ProgressPreference

try {
    if ($ProgressPreference -ne 'Continue') { $ProgressPreference = 'Continue' }

    if ($AboutRefreshMode -notin 1,2,3) {
        throw "Invalid AboutRefreshMode '$AboutRefreshMode'. Must be 1 (NoAction), 2 (DeleteOnly), or 3 (CheckAndUpdate)."
    }

    # TLS hardening for Windows PowerShell 5.1
    try {
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.SecurityProtocolType]::Tls12 -bor
                [Net.SecurityProtocolType]::Tls11 -bor
                [Net.SecurityProtocolType]::Tls
        }
    } catch { }

    # Determine script directory reliably
    $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $DefaultUrlPath = Join-Path $ScriptDir $DefaultUrlFileName

    # ---------------------------
    # Utility helpers
    # ---------------------------

    function Resolve-RepoAboutUrlFilePath {
        param([Parameter(Mandatory)][string]$CandidatePath)

        if (Test-Path -LiteralPath $CandidatePath) {
            return (Resolve-Path -LiteralPath $CandidatePath).Path
        }

        Write-Host ""
        Write-Host "URL file not found at:" -ForegroundColor Yellow
        Write-Host "  $CandidatePath" -ForegroundColor Yellow
        Write-Host ""

        while ($true) {
            $entered = Read-Host "Enter full path to URL file (or press Enter to exit)"
            if ([string]::IsNullOrWhiteSpace($entered)) { throw "No URL file selected. Exiting." }

            $maybe = $entered
            if (-not [System.IO.Path]::IsPathRooted($maybe)) {
                $maybe = Join-Path (Get-Location) $maybe
            }

            if (Test-Path -LiteralPath $maybe) {
                return (Resolve-Path -LiteralPath $maybe).Path
            }

            Write-Host "Not found: $maybe" -ForegroundColor Red
        }
    }

    function Get-RepoAboutBackupStem {
        param(
            [Parameter(Mandatory)][string]$TargetPath,
            [Parameter(Mandatory)][bool]$DropExtension
        )

        $dir  = Split-Path -Parent $TargetPath
        $leaf = Split-Path -Leaf   $TargetPath

        if (-not $DropExtension) { return "$TargetPath.bak" }

        $noExt = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        return (Join-Path $dir ($noExt + '.bak'))
    }

    function Get-RepoAboutExistingBackups {
        param(
            [Parameter(Mandatory)][string]$TargetPath,
            [Parameter(Mandatory)][bool]$DropExtension
        )

        $base = Get-RepoAboutBackupStem -TargetPath $TargetPath -DropExtension $DropExtension
        $dir  = Split-Path -Parent $base
        $leaf = Split-Path -Leaf   $base

        if (-not (Test-Path -LiteralPath $dir)) { return @() }

        $rx = ('^{0}(\d+)?$' -f [regex]::Escape($leaf))

        $items = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $rx } |
            ForEach-Object {
                $suffix = 0
                if ($_.Name -match $rx -and $Matches[1]) { $suffix = [int]$Matches[1] }
                [pscustomobject]@{ Path = $_.FullName; Suffix = $suffix }
            } |
            Sort-Object Suffix

        return @($items) # force array
    }

    function Get-RepoAboutNextBackupPath {
        param(
            [Parameter(Mandatory)][string]$TargetPath,
            [bool]$DropExtension = $true
        )

        $existing = @(Get-RepoAboutExistingBackups -TargetPath $TargetPath -DropExtension $DropExtension)
        $base = Get-RepoAboutBackupStem -TargetPath $TargetPath -DropExtension $DropExtension

        if ($existing.Count -eq 0) { return $base }

        $max = ($existing | Measure-Object -Property Suffix -Maximum).Maximum
        if ($null -eq $max) { return $base }

        return ('{0}{1}' -f $base, ([int]$max + 1))
    }

    function Invoke-RepoAboutBackupRetention {
        param(
            [Parameter(Mandatory)][string]$TargetPath,
            [Parameter(Mandatory)][bool]$DropExtension,
            [Parameter(Mandatory)][int]$KeepCount
        )

        if ($KeepCount -le 0) { return } # keep all backups

        $existing = @(Get-RepoAboutExistingBackups -TargetPath $TargetPath -DropExtension $DropExtension)
        if ($existing.Count -le $KeepCount) { return }

        $toDelete = $existing | Sort-Object Suffix | Select-Object -First ($existing.Count - $KeepCount)
        foreach ($b in $toDelete) {
            try {
                Remove-Item -LiteralPath $b.Path -Force -ErrorAction Stop
                Write-Verbose ("Deleted old backup: {0}" -f $b.Path)
            } catch {
                Write-Warning ("Failed to delete old backup: {0} ({1})" -f $b.Path, $_.Exception.Message)
            }
        }
    }

    # TrimStart that removes BOM + tab + space safely
    $TrimChars = [char[]]@([char]0xFEFF, [char]9, [char]32)
    function Get-RepoAboutTrimStart {
        param(
            [AllowNull()]
            [AllowEmptyString()]
            [string]$Line
        )
        if ($null -eq $Line) { return '' }
        return $Line.TrimStart($TrimChars)
    }

    function Test-RepoAboutProgressSupported {
        if (-not $ShowProgress) { return $false }
        if (-not $Host -or -not $Host.UI -or -not $Host.UI.RawUI) { return $false }
        return $true
    }

    $ProgressOk = Test-RepoAboutProgressSupported
    if (-not $ProgressOk -and $ForceVerboseIfNoProgress) {
        $VerbosePreference = 'Continue'
        Write-Verbose "Progress UI not supported by this host. Switching to verbose status output."
    }

    function Get-RepoAboutNowTimestamp {
        return (Get-Date).ToString($AboutTimestampFormat, [System.Globalization.CultureInfo]::InvariantCulture)
    }

    function Convert-RepoAboutIsoToLocalTimestamp {
        param([AllowNull()][AllowEmptyString()][string]$IsoString)

        if ([string]::IsNullOrWhiteSpace($IsoString)) { return $null }
        try {
            $dto = [DateTimeOffset]::Parse($IsoString, [System.Globalization.CultureInfo]::InvariantCulture)
            $local = $dto.ToLocalTime()
            return $local.ToString($AboutTimestampFormat, [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }

    function Get-RepoAboutSlugFromUrl {
        param([Parameter(Mandatory)][string]$Url)

        try {
            $u = [Uri]$Url
            $path = $u.AbsolutePath.Trim('/')
            if ([string]::IsNullOrWhiteSpace($path)) { return $null }

            $parts = $path.Split('/') | Where-Object { $_ -ne '' }
            if ($parts.Count -ge 2) {
                $repo = $parts[1]
                if ($repo.EndsWith('.git')) { $repo = $repo.Substring(0, $repo.Length - 4) }
                return ('{0}/{1}' -f $parts[0], $repo)
            }
        } catch { }

        return $null
    }

    function Split-RepoAboutTimestamp {
        param([AllowNull()][AllowEmptyString()][string]$AboutText)

        if ([string]::IsNullOrWhiteSpace($AboutText)) {
            return [pscustomobject]@{ Base = $null; Timestamp = $null }
        }

        $s = $AboutText.Trim()
        $m = [regex]::Match($s, '\s*\[(?<ts>\d{2}/\d{2}/\d{4}\s*-\s*\d{2}:\d{2})\]\s*$')
        if ($m.Success) {
            $base = $s.Substring(0, $m.Index).Trim()
            $ts = $m.Groups['ts'].Value.Trim()
            return [pscustomobject]@{ Base = $base; Timestamp = $ts }
        }

        return [pscustomobject]@{ Base = $s; Timestamp = $null }
    }

    function Get-RepoAboutCleanBase {
        <#
          Cleans About base text:
            - removes the full URL if present
            - removes owner/repo slug if present (esp. as trailing suffix)
            - strips trailing "GitHub"/"GitLab" ONLY if at end
            - trims leftover punctuation/spaces
        #>
        param(
            [AllowNull()][AllowEmptyString()][string]$AboutBase,
            [Parameter(Mandatory)][string]$Url
        )

        if ([string]::IsNullOrWhiteSpace($AboutBase)) { return $null }
        $clean = $AboutBase.Trim()

        # Remove full URL if present (case-insensitive)
        $clean = [regex]::Replace($clean, [regex]::Escape($Url), '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase).Trim()

        # Remove slug patterns
        $slug = Get-RepoAboutSlugFromUrl -Url $Url
        if (-not [string]::IsNullOrWhiteSpace($slug)) {
            $escSlug = [regex]::Escape($slug)

            $clean = [regex]::Replace($clean, "\s*(?:-+|—|–|\||·|:)\s*$escSlug\s*$", '', 'IgnoreCase').Trim()
            $clean = [regex]::Replace($clean, "\s*[\(\[\{]\s*$escSlug\s*[\)\]\}]\s*$", '', 'IgnoreCase').Trim()
            $clean = [regex]::Replace($clean, "\s+$escSlug\s*$", '', 'IgnoreCase').Trim()
        }

        # Strip GitHub/GitLab suffix ONLY if at end (optionally preceded by separators)
        $clean = [regex]::Replace($clean, "\s*(?:-+|—|–|\||·|:)?\s*(GitHub|GitLab)\s*$", '', 'IgnoreCase').Trim()

        # Cleanup trailing separators/punct
        $clean = $clean.TrimEnd('-', '—', '–', '|', '·', ':', '.', ' ')
        $clean = $clean.Trim()

        return $clean
    }

    function Format-RepoAboutLine {
        param(
            [Parameter(Mandatory)][string]$AboutBase,
            [Parameter(Mandatory)][string]$TimestampText
        )
        return ($AboutPrefix + $AboutBase + " [$TimestampText]")
    }

    # ---------------------------
    # Repo API resolution helpers
    # ---------------------------

    function Get-RepoApiRequestInfo {
        <#
          Returns an object describing how to fetch:
            - Provider: GitHub / GitLab / Other
            - ApiUrl: API endpoint for metadata
        #>
        param([Parameter(Mandatory)][string]$Url)

        try {
            $u = [Uri]$Url
        } catch {
            return [pscustomobject]@{ Provider='Other'; ApiUrl=$null }
        }

        $host = $u.Host.ToLowerInvariant()
        $path = $u.AbsolutePath.Trim('/')

        if ([string]::IsNullOrWhiteSpace($path)) {
            return [pscustomobject]@{ Provider='Other'; ApiUrl=$null }
        }

        $segments = $path.Split('/') | Where-Object { $_ -ne '' }

        # Strip GitHub extra path parts (tree/blob/issues/pulls etc.)
        if ($host -like '*github*') {
            if ($segments.Count -lt 2) { return [pscustomobject]@{ Provider='GitHub'; ApiUrl=$null } }
            $owner = $segments[0]
            $repo  = $segments[1]
            if ($repo.EndsWith('.git')) { $repo = $repo.Substring(0, $repo.Length - 4) }

            # GitHub.com uses api.github.com; GitHub Enterprise usually /api/v3
            if ($host -eq 'github.com') {
                $api = "https://api.github.com/repos/$owner/$repo"
            } else {
                $api = "https://$host/api/v3/repos/$owner/$repo"
            }

            return [pscustomobject]@{ Provider='GitHub'; ApiUrl=$api }
        }

        # GitLab: stop at "/-/" if present, otherwise use full group/subgroup/project path
        if ($host -like '*gitlab*') {
            if ($segments.Count -lt 2) { return [pscustomobject]@{ Provider='GitLab'; ApiUrl=$null } }

            $stopIndex = $segments.IndexOf('-')
            if ($stopIndex -gt 0) {
                $projSegments = $segments[0..($stopIndex-1)]
            } else {
                $projSegments = $segments
            }

            $projSegments[-1] = $projSegments[-1] -replace '\.git$', ''
            $projectPath = ($projSegments -join '/')
            $encoded = [Uri]::EscapeDataString($projectPath)

            $api = "https://$host/api/v4/projects/$encoded"
            return [pscustomobject]@{ Provider='GitLab'; ApiUrl=$api }
        }

        return [pscustomobject]@{ Provider='Other'; ApiUrl=$null }
    }

    # ---------------------------
    # RunspacePool fetcher (PS5/PS7) using API for About + repo last-updated
    # ---------------------------
    function Invoke-RepoAboutFetchMapRunspace {
        param(
            [Parameter(Mandatory)][string[]]$Urls,
            [Parameter(Mandatory)][int]$Throttle,
            [Parameter(Mandatory)][int]$TimeoutSec,
            [Parameter(Mandatory)][int]$HardHangSec,
            [Parameter(Mandatory)][int]$Max429Retries,
            [Parameter(Mandatory)][int]$DefaultRetryAfterSec,
            [bool]$ShowProgress = $false,
            [string]$ProgressActivity = "Fetching Repo Metadata",
            [int]$VerboseEveryNCompletions = 10,
            [switch]$Disable429RetriesForProbe
        )

        # Map[url] = object { AboutRaw, RepoUpdatedIso, HttpCode, Error }
        $map  = @{}
        $rateLimitCount = 0
        $notFoundCount  = 0
        $hangDetected   = $false

        if (-not $Urls -or $Urls.Count -eq 0) {
            return [pscustomobject]@{
                Map            = $map
                RateLimitCount = 0
                NotFoundCount  = 0
                HangDetected   = $false
            }
        }

        $iss  = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Throttle, $iss, $Host)
        $pool.Open()

        $jobs = New-Object System.Collections.Generic.List[object]
        $total = $Urls.Count
        $completed = 0

        $sb = {
            param($u, $timeoutSec, $max429Retries, $defaultRetryAfterSec, $disable429RetriesForProbe)

            # TLS for PS5
            try {
                if ($PSVersionTable.PSVersion.Major -lt 6) {
                    [Net.ServicePointManager]::SecurityProtocol =
                        [Net.SecurityProtocolType]::Tls12 -bor
                        [Net.SecurityProtocolType]::Tls11 -bor
                        [Net.SecurityProtocolType]::Tls
                }
            } catch { }

            function Get-RetryAfterSeconds {
                param(
                    [System.Net.Http.Headers.HttpResponseHeaders]$Headers,
                    [int]$DefaultSec
                )

                try {
                    $ra = $Headers.RetryAfter
                    if ($null -ne $ra) {
                        if ($ra.Delta) {
                            $sec = [Math]::Ceiling($ra.Delta.TotalSeconds)
                            if ($sec -gt 0) { return [int]$sec }
                        }
                        if ($ra.Date) {
                            $sec = [Math]::Ceiling(($ra.Date.UtcDateTime - [DateTime]::UtcNow).TotalSeconds)
                            if ($sec -gt 0) { return [int]$sec }
                        }
                    }
                } catch { }

                return [int]$DefaultSec
            }

            function Get-RequestInfoLocal {
                param([string]$Url)

                try { $uri = [Uri]$Url } catch { return @{ Provider='Other'; ApiUrl=$null } }

                $host = $uri.Host.ToLowerInvariant()
                $path = $uri.AbsolutePath.Trim('/')
                if ([string]::IsNullOrWhiteSpace($path)) { return @{ Provider='Other'; ApiUrl=$null } }

                $segments = $path.Split('/') | Where-Object { $_ -ne '' }

                if ($host -like '*github*') {
                    if ($segments.Count -lt 2) { return @{ Provider='GitHub'; ApiUrl=$null } }
                    $owner = $segments[0]
                    $repo  = $segments[1]
                    if ($repo.EndsWith('.git')) { $repo = $repo.Substring(0, $repo.Length - 4) }

                    if ($host -eq 'github.com') {
                        $api = "https://api.github.com/repos/$owner/$repo"
                    } else {
                        $api = "https://$host/api/v3/repos/$owner/$repo"
                    }

                    return @{ Provider='GitHub'; ApiUrl=$api }
                }

                if ($host -like '*gitlab*') {
                    if ($segments.Count -lt 2) { return @{ Provider='GitLab'; ApiUrl=$null } }

                    $stopIndex = $segments.IndexOf('-')
                    if ($stopIndex -gt 0) { $projSegments = $segments[0..($stopIndex-1)] } else { $projSegments = $segments }

                    $projSegments[-1] = ($projSegments[-1] -replace '\.git$', '')
                    $projectPath = ($projSegments -join '/')
                    $encoded = [Uri]::EscapeDataString($projectPath)
                    $api = "https://$host/api/v4/projects/$encoded"

                    return @{ Provider='GitLab'; ApiUrl=$api }
                }

                return @{ Provider='Other'; ApiUrl=$null }
            }

            $info = Get-RequestInfoLocal -Url $u
            $provider = $info.Provider
            $apiUrl = $info.ApiUrl

            if ([string]::IsNullOrWhiteSpace($apiUrl)) {
                return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$null; Error="No API mapping for URL" }
            }

            $handler = $null
            $client  = $null

            try {
                $handler = New-Object System.Net.Http.HttpClientHandler
                $handler.AllowAutoRedirect = $true

                $client = New-Object System.Net.Http.HttpClient($handler)
                $client.Timeout = [TimeSpan]::FromSeconds($timeoutSec)

                # Required for GitHub API; also fine for GitLab
                $client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/GetAbout")
                $client.DefaultRequestHeaders.Accept.ParseAdd("application/json")

                $attempt = 0
                while ($true) {
                    $attempt++

                    try {
                        $resp = $client.GetAsync($apiUrl).GetAwaiter().GetResult()
                    } catch {
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$null; Error=$_.Exception.Message }
                    }

                    $code = [int]$resp.StatusCode

                    if ($code -eq 429) {
                        $ra = Get-RetryAfterSeconds -Headers $resp.Headers -DefaultSec $defaultRetryAfterSec
                        if (-not $disable429RetriesForProbe -and $attempt -le $max429Retries) {
                            Start-Sleep -Seconds $ra
                            continue
                        }
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$code; Error="HTTP 429 Rate Limited" }
                    }

                    if ($code -eq 404) {
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$code; Error="HTTP 404 Not Found" }
                    }

                    if (-not $resp.IsSuccessStatusCode) {
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$code; Error=("HTTP {0}" -f $code) }
                    }

                    $json = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    if ([string]::IsNullOrWhiteSpace($json)) {
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$code; Error="Empty response body" }
                    }

                    try {
                        $obj = $json | ConvertFrom-Json -ErrorAction Stop
                    } catch {
                        return [pscustomobject]@{ Url=$u; AboutRaw=$null; RepoUpdatedIso=$null; HttpCode=$code; Error="Failed to parse JSON" }
                    }

                    $about = $null
                    $updatedIso = $null

                    if ($provider -eq 'GitHub') {
                        $about = $obj.description
                        # prefer pushed_at (actual code pushes), fallback updated_at
                        if ($obj.pushed_at) { $updatedIso = [string]$obj.pushed_at }
                        elseif ($obj.updated_at) { $updatedIso = [string]$obj.updated_at }
                    }
                    elseif ($provider -eq 'GitLab') {
                        $about = $obj.description
                        if ($obj.last_activity_at) { $updatedIso = [string]$obj.last_activity_at }
                    }

                    if (-not [string]::IsNullOrWhiteSpace($about)) {
                        $about = $about.Trim()
                    } else {
                        $about = $null
                    }

                    return [pscustomobject]@{ Url=$u; AboutRaw=$about; RepoUpdatedIso=$updatedIso; HttpCode=$code; Error=$null }
                }
            }
            finally {
                if ($client)  { $client.Dispose() }
                if ($handler) { $handler.Dispose() }
            }
        }

        foreach ($u in $Urls) {
            $ps = [System.Management.Automation.PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($sb).
                AddArgument($u).
                AddArgument($TimeoutSec).
                AddArgument($Max429Retries).
                AddArgument($DefaultRetryAfterSec).
                AddArgument([bool]$Disable429RetriesForProbe)

            $handle = $ps.BeginInvoke()

            $jobs.Add([pscustomobject]@{
                PS       = $ps
                Handle   = $handle
                Url      = $u
                StartUtc = [DateTime]::UtcNow
            }) | Out-Null
        }

        while ($jobs.Count -gt 0) {
            for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
                $j = $jobs[$i]

                if ($j.Handle.IsCompleted) {
                    try {
                        $res = $j.PS.EndInvoke($j.Handle)
                        foreach ($r in $res) {
                            $map[$r.Url] = $r
                            if ($r.HttpCode -eq 429) { $rateLimitCount++ }
                            if ($r.HttpCode -eq 404) { $notFoundCount++ }
                            if ($r.Error) { Write-Verbose ("Fetch issue: {0} ({1})" -f $r.Url, $r.Error) }
                        }
                    } finally {
                        $j.PS.Dispose()
                    }

                    $jobs.RemoveAt($i)
                    $completed++

                    if ($ShowProgress) {
                        $pct = ($completed / [double]$total) * 100
                        Write-Progress -Activity "$ProgressActivity (Throttle=$Throttle)" -Status "$completed / $total" -PercentComplete $pct
                    }
                    elseif ($VerbosePreference -eq 'Continue') {
                        if (($completed % [Math]::Max(1, $VerboseEveryNCompletions) -eq 0) -or ($completed -eq $total)) {
                            Write-Verbose ("{0}: {1}/{2} completed (Throttle={3}, 429={4}, 404={5})" -f $ProgressActivity, $completed, $total, $Throttle, $rateLimitCount, $notFoundCount)
                        }
                    }

                    continue
                }

                $elapsed = ([DateTime]::UtcNow - $j.StartUtc).TotalSeconds
                if ($elapsed -gt $HardHangSec) {
                    $hangDetected = $true
                    Write-Warning "Hang detected (>$HardHangSec sec): $($j.Url)"
                    try { $j.PS.Dispose() } catch { }
                    $jobs.RemoveAt($i)
                    $completed++
                }
            }

            Start-Sleep -Milliseconds 100
        }

        if ($ShowProgress) { Write-Progress -Activity "$ProgressActivity (Throttle=$Throttle)" -Completed }

        $pool.Close()
        $pool.Dispose()

        return [pscustomobject]@{
            Map            = $map
            RateLimitCount = $rateLimitCount
            NotFoundCount  = $notFoundCount
            HangDetected   = $hangDetected
        }
    }

    function Find-RepoAboutSmartThrottle {
        param([Parameter(Mandatory)][string[]]$Urls)

        if (-not $EnableSmartParallel) { return $FixedThrottle }
        if (-not $Urls -or $Urls.Count -eq 0) { return $FixedThrottle }

        $sample = if ($Urls.Count -gt $SmartSampleSize) { $Urls | Select-Object -First $SmartSampleSize } else { $Urls }
        $best = $StartSmartThrottle

        for ($t = $StartSmartThrottle; $t -le $MaxSmartThrottle; $t++) {
            if ($ProgressOk) {
                $pct = ($t / [double]$MaxSmartThrottle) * 100
                Write-Progress -Activity "Smart parallel calibration" -Status "Testing throttle $t (best=$best)" -PercentComplete $pct
            }

            # Probe with 429 retries disabled (avoid long sleeps during calibration)
            $probe = Invoke-RepoAboutFetchMapRunspace -Urls $sample -Throttle $t -TimeoutSec $TimeoutSec -HardHangSec $HardHangSec `
                -Max429Retries $Max429Retries -DefaultRetryAfterSec $DefaultRetryAfterSec -ShowProgress:$false -ProgressActivity "Calibration" `
                -VerboseEveryNCompletions 99999 -Disable429RetriesForProbe

            if ($probe.HangDetected -or $probe.RateLimitCount -gt 0) { break }
            $best = $t
        }

        if ($ProgressOk) { Write-Progress -Activity "Smart parallel calibration" -Completed }
        return $best
    }

    # ---------------------------
    # MAIN
    # ---------------------------

    $UrlPath  = Resolve-RepoAboutUrlFilePath -CandidatePath $DefaultUrlPath
    $InputDir = Split-Path -Parent $UrlPath

    $OutPath = $null
    if (-not $ReplaceInputFile) {
        $OutPath = if ([System.IO.Path]::IsPathRooted($DefaultOutputFileName)) {
            $DefaultOutputFileName
        } else {
            Join-Path $InputDir $DefaultOutputFileName
        }
    }

    $lines = Get-Content -LiteralPath $UrlPath

    $urlLineRegex   = [regex]'^\s*(https?://\S+)(?<rest>.*)$'
    $aboutLineRegex = [regex]'^\s*#\s*About\s*:\s*(?<a>.*)$'

    $EffectiveUrlIndent = if ($RemoveUrlIndentation) { '' } else { $UrlIndent }

    # Collect URLs only when mode 3
    $urlList = @()
    if ($AboutRefreshMode -eq 3) {
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in $lines) {
            $ts = Get-RepoAboutTrimStart -Line $line
            if ($ts.StartsWith('##')) { continue }
            $m = $urlLineRegex.Match($line)
            if ($m.Success) {
                $u = $m.Groups[1].Value.TrimEnd(')',']','>','"',"'",',','.')
                [void]$set.Add($u)
            }
        }
        foreach ($u in $set) { $urlList += $u }
    }

    # Fetch only in mode 3
    $repoMetaMap = @{}   # url -> object {AboutRaw, RepoUpdatedIso, HttpCode, Error}
    if ($AboutRefreshMode -eq 3 -and $urlList.Count -gt 0) {
        $throttle = Find-RepoAboutSmartThrottle -Urls $urlList
        Write-Host "Selected throttle: $throttle" -ForegroundColor Cyan

        $fetch = Invoke-RepoAboutFetchMapRunspace -Urls $urlList -Throttle $throttle -TimeoutSec $TimeoutSec -HardHangSec $HardHangSec `
            -Max429Retries $Max429Retries -DefaultRetryAfterSec $DefaultRetryAfterSec -ShowProgress:$ProgressOk -ProgressActivity "Fetching Repo Metadata" `
            -VerboseEveryNCompletions $VerboseEveryNCompletions

        $repoMetaMap = $fetch.Map
    }

    # Rewrite deterministically
    $outLines = New-Object System.Collections.Generic.List[string]

    $pendingAboutBase = $null
    $pendingAboutTs   = $null

    function Clear-RepoAboutPending {
        $script:pendingAboutBase = $null
        $script:pendingAboutTs   = $null
    }

    function Write-RepoAboutOrphanIfNeeded {
        if ($null -ne $script:pendingAboutBase) {
            if (-not $RemoveOrphanAboutLines -and $AboutRefreshMode -ne 2) {
                $ts = if ([string]::IsNullOrWhiteSpace($script:pendingAboutTs)) { Get-RepoAboutNowTimestamp } else { $script:pendingAboutTs }
                $outLines.Add((Format-RepoAboutLine -AboutBase $script:pendingAboutBase -TimestampText $ts)) | Out-Null
            }
            Clear-RepoAboutPending
        }
    }

    $rewriteTotal = $lines.Count
    $rewriteDone  = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $ts   = Get-RepoAboutTrimStart -Line $line

        if ($ts.StartsWith('##')) {
            Write-RepoAboutOrphanIfNeeded
            $outLines.Add($line) | Out-Null
        }
        else {
            $am = $aboutLineRegex.Match($line)
            if ($am.Success) {
                Write-RepoAboutOrphanIfNeeded
                $split = Split-RepoAboutTimestamp -AboutText ($am.Groups['a'].Value)
                $pendingAboutBase = $split.Base
                $pendingAboutTs   = $split.Timestamp
            }
            elseif ([string]::IsNullOrWhiteSpace($line)) {
                Write-RepoAboutOrphanIfNeeded
                $outLines.Add($line) | Out-Null
            }
            elseif ($ts.StartsWith('#')) {
                # Drop all non-About comments
                Write-RepoAboutOrphanIfNeeded
            }
            else {
                $um = $urlLineRegex.Match($line)
                if ($um.Success) {
                    $url  = $um.Groups[1].Value.TrimEnd(')',']','>','"',"'",',','.')
                    $rest = if ($StripTrailingTextAfterUrl) { '' } else { $um.Groups['rest'].Value }

                    # Existing base + timestamp
                    $existingSplit = Split-RepoAboutTimestamp -AboutText $pendingAboutBase
                    $existingBaseClean = Get-RepoAboutCleanBase -AboutBase $existingSplit.Base -Url $url
                    $existingTs = $pendingAboutTs

                    if ($AboutRefreshMode -eq 2) {
                        # DeleteOnly: no About line
                        $outLines.Add($EffectiveUrlIndent + $url + $rest) | Out-Null
                    }
                    elseif ($AboutRefreshMode -eq 1) {
                        # NoAction: keep existing About (sanitized); timestamp only if missing/changed by sanitization
                        if (-not [string]::IsNullOrWhiteSpace($existingBaseClean)) {
                            $changed = ($existingSplit.Base -ne $existingBaseClean)
                            if ($changed -or [string]::IsNullOrWhiteSpace($existingTs)) {
                                $existingTs = Get-RepoAboutNowTimestamp
                            }
                            $outLines.Add((Format-RepoAboutLine -AboutBase $existingBaseClean -TimestampText $existingTs)) | Out-Null
                        }
                        $outLines.Add($EffectiveUrlIndent + $url + $rest) | Out-Null
                    }
                    else {
                        # Mode 3: CheckAndUpdate (timestamp = repo last-updated time when available)
                        $meta = $null
                        if ($repoMetaMap.ContainsKey($url)) { $meta = $repoMetaMap[$url] }

                        $httpCode = $null
                        $aboutRaw = $null
                        $repoUpdatedIso = $null

                        if ($meta) {
                            $httpCode = $meta.HttpCode
                            $aboutRaw = $meta.AboutRaw
                            $repoUpdatedIso = $meta.RepoUpdatedIso
                        }

                        $repoUpdatedTs = Convert-RepoAboutIsoToLocalTimestamp -IsoString $repoUpdatedIso

                        $fetchedClean = Get-RepoAboutCleanBase -AboutBase $aboutRaw -Url $url

                        $finalBase = $null
                        $finalTs   = $existingTs

                        if ($httpCode -eq 404) {
                            $finalBase = $NotFoundText
                            # repo updated time unknown; timestamp when we set this state
                            $finalTs = Get-RepoAboutNowTimestamp
                        }
                        elseif ($httpCode -eq 429) {
                            # Can't verify; keep existing if present else label. Timestamp = existing if present else now.
                            if (-not [string]::IsNullOrWhiteSpace($existingBaseClean)) {
                                $finalBase = $existingBaseClean
                                if ([string]::IsNullOrWhiteSpace($finalTs)) { $finalTs = Get-RepoAboutNowTimestamp }
                            } else {
                                $finalBase = $RateLimitedText
                                $finalTs = Get-RepoAboutNowTimestamp
                            }
                        }
                        else {
                            # Successful or best-effort (no explicit error)
                            if (-not [string]::IsNullOrWhiteSpace($fetchedClean)) {
                                # Update base only if changed
                                if ($existingBaseClean -ne $fetchedClean) {
                                    $finalBase = $fetchedClean
                                } else {
                                    $finalBase = $existingBaseClean
                                }

                                # Timestamp should represent repo last-updated time (preferred)
                                if (-not [string]::IsNullOrWhiteSpace($repoUpdatedTs)) {
                                    $finalTs = $repoUpdatedTs
                                } else {
                                    # fallback: keep existing ts or set now if missing
                                    if ([string]::IsNullOrWhiteSpace($finalTs)) { $finalTs = Get-RepoAboutNowTimestamp }
                                }
                            }
                            elseif (-not [string]::IsNullOrWhiteSpace($existingBaseClean)) {
                                $finalBase = $existingBaseClean
                                # If we managed to get repoUpdatedTs, still apply it
                                if (-not [string]::IsNullOrWhiteSpace($repoUpdatedTs)) {
                                    $finalTs = $repoUpdatedTs
                                } elseif ([string]::IsNullOrWhiteSpace($finalTs)) {
                                    $finalTs = Get-RepoAboutNowTimestamp
                                }
                            }
                            else {
                                $finalBase = $AboutNotFoundText
                                $finalTs = if (-not [string]::IsNullOrWhiteSpace($repoUpdatedTs)) { $repoUpdatedTs } else { Get-RepoAboutNowTimestamp }
                            }
                        }

                        $outLines.Add((Format-RepoAboutLine -AboutBase $finalBase -TimestampText $finalTs)) | Out-Null
                        $outLines.Add($EffectiveUrlIndent + $url + $rest) | Out-Null
                    }

                    Clear-RepoAboutPending
                }
                else {
                    Write-RepoAboutOrphanIfNeeded
                    $outLines.Add($line) | Out-Null
                }
            }
        }

        $rewriteDone++
        if ($ProgressOk) {
            $pct = ($rewriteDone / [double]$rewriteTotal) * 100
            Write-Progress -Activity "Rewriting file" -Status "$rewriteDone / $rewriteTotal" -PercentComplete $pct
        }
        elseif ($VerbosePreference -eq 'Continue') {
            if (($rewriteDone % 200 -eq 0) -or ($rewriteDone -eq $rewriteTotal)) {
                Write-Verbose ("Rewriting file: {0}/{1}" -f $rewriteDone, $rewriteTotal)
            }
        }
    }

    Write-RepoAboutOrphanIfNeeded
    if ($ProgressOk) { Write-Progress -Activity "Rewriting file" -Completed }

    # ---------------------------
    # WRITE OUTPUT + BACKUPS + RETENTION
    # ---------------------------

    if ($ReplaceInputFile) {
        $backup = Get-RepoAboutNextBackupPath -TargetPath $UrlPath -DropExtension $BackupDropExtension
        Copy-Item -LiteralPath $UrlPath -Destination $backup -Force

        Invoke-RepoAboutBackupRetention -TargetPath $UrlPath -DropExtension $BackupDropExtension -KeepCount $MaxBackupsToKeep

        Set-Content -LiteralPath $UrlPath -Value $outLines -Encoding UTF8

        Write-Host "Updated input file in place: $UrlPath" -ForegroundColor Green
        Write-Host "Backup created:             $backup" -ForegroundColor DarkGray
    }
    else {
        if ($BackupOutputIfExists -and (Test-Path -LiteralPath $OutPath)) {
            $outBackup = Get-RepoAboutNextBackupPath -TargetPath $OutPath -DropExtension $BackupDropExtension
            Move-Item -LiteralPath $OutPath -Destination $outBackup -Force
            Write-Host "Existing output backed up:  $outBackup" -ForegroundColor DarkGray

            Invoke-RepoAboutBackupRetention -TargetPath $OutPath -DropExtension $BackupDropExtension -KeepCount $MaxBackupsToKeep
        }

        Set-Content -LiteralPath $OutPath -Value $outLines -Encoding UTF8
        Write-Host "Wrote output:               $OutPath" -ForegroundColor Green
    }

}
finally {
    # Restore ProgressPreference no matter what
    $ProgressPreference = $__OriginalProgressPreference
}