# =====================================================================# ================================================================= synchronizer (PS5.1+ / PS7+)
#
# FEATURES
#   - Reads urls.txt (same folder)
#   - Ignores lines starting with '#' (comments)
#   - GitHub => SSH (git@github.com:owner/repo.git)
#   - GitLab => SSH (Option A) -> git@gitlab.host:group/sub/repo.git
#   - Owner/namespace-prefixed directories:
#       GitHub: owner__repo
#       GitLab: group__subgroup__repo
#   - Content-aware updates using TREE IDs (avoids churn)
#   - Progress bar + heartbeat
#
# RESILIENCY
#   - SSH fail-fast (BatchMode + timeouts)
#   - Per-git-command timeout kills process tree (taskkill /T on Windows)
#   - Per-repo runspace max timeout
#   - index.lock stale cleanup + retry
#
# IMPORTANT
#   - No `$Args` parameter/variable (avoids collision with `$args`)
#   - No `-f` format strings containing `{tree}` (avoids formatting exceptions)
#   - Uses WorkingDirectory (safe with spaces in folder names)
# =====================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:GIT_TERMINAL_PROMPT = '0'

# -------------------------- USER SETTINGS -----------------------------
$UrlsMode          = 'Default'  # Default|Sort|Report|SortAndReport|NoDedupe
$RepoMode          = 'Sync'     # Sync|UpdateOnly|CloneOnly|ListOnly
$DebugFailures     = $true
$GitNoProgressArgs = @('--no-progress')

# --- GitLab transport (Option A) ---
$GitLabTransport   = 'SSH'
$GitLabSshUser     = 'git'

# --- SSH fail-fast for ALL SSH operations ---
$ForceSshBatchMode   = $true
$AcceptNewHostKeys   = $false
$SshConnectTimeout   = 10
$SshServerAliveInt   = 15
$SshServerAliveCount = 2
$SshPreferredAuth    = 'publickey'

# --- Parallel / throttle ---
$UseParallel         = $true
$FixedThrottle       = 5
$ProgressUpdateMs    = 350
$HeartbeatSeconds    = 10

# --- Timeouts (seconds) ---
$FetchTimeoutSeconds       = 300
$ResetTimeoutSeconds       = 300
$CloneTimeoutSeconds       = 1200
$PerRepoRunspaceMaxSeconds = 1800  # 30 minutes cap per repo overall

# --- Rename-on-update ---
$RenameOnUpdate   = $true
$RenameFormat     = 'yyyyMMdd-HHmm'
$RenameSeparator  = ' '

# --- index.lock handling ---
$AutoFixIndexLock = $true
$LockStaleMinutes = 10
$LockRetryCount   = 1

# --- Progress bar knobs ---
$ForceProgressBarInShell = $true

# --- Verbosity knobs ---
$ShowPerRepoStatus  = $true
$ShowRepoStartLines = $false
# ---------------------------------------------------------------------


# ----------------------------- Paths ---------------------------------
$ScriptDirectory  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$InitialDirectory = Get-Location
Set-Location -Path $ScriptDirectory

# Validate git availability early (fail fast)
try { Get-Command git -ErrorAction Stop | Out-Null }
catch { throw "git.exe not found in PATH. Install Git for Windows or fix PATH." }

try { git config --global core.longpaths true | Out-Null } catch {}

# --------------------------- Summary ---------------------------------
[int]$TotalRepos     = 0
[int]$ClonedRepos    = 0
[int]$UpdatedRepos   = 0
[int]$UnchangedRepos = 0
[int]$SkippedRepos   = 0
[int]$ErrorRepos     = 0

# --------------------------- Helpers ---------------------------------

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }

function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$Pid)
    if (Test-IsWindows) {
        try { & taskkill.exe /PID $Pid /T /F | Out-Null } catch { }
    } else {
        try { Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-SshCommand {
    $opts = @()
    if ($ForceSshBatchMode) { $opts += '-o BatchMode=yes' }
    if ($AcceptNewHostKeys) { $opts += '-o StrictHostKeyChecking=accept-new' }
    if ($SshConnectTimeout -gt 0) { $opts += ("-o ConnectTimeout={0}" -f $SshConnectTimeout) }
    if ($SshServerAliveInt -gt 0) { $opts += ("-o ServerAliveInterval={0}" -f $SshServerAliveInt) }
    if ($SshServerAliveCount -gt 0) { $opts += ("-o ServerAliveCountMax={0}" -f $SshServerAliveCount) }
    if ($SshPreferredAuth) { $opts += ("-o PreferredAuthentications={0}" -f $SshPreferredAuth) }
    if ($opts.Count -gt 0) { return "ssh " + ($opts -join ' ') }
    return $null
}

function ConvertTo-NormalizedUrlKey {
    param([string]$Url)
    (($Url.Trim().TrimEnd('/')) -replace '\.git$','').ToLowerInvariant()
}

function ConvertTo-SafePart {
    param([string]$Text)
    ($Text -replace '[^\w\.-]','_')
}

function Test-IsGitLabUrl {
    param([string]$Url)
    try { ([uri]$Url).Host -match '(?i)gitlab' } catch { $Url -match '(?i)\bgitlab\b' }
}

function Get-GitHubRepoRootWebUrl {
    param([string]$Url)
    if ($Url -match '^https://github\.com/(?<o>[^/]+)/(?<r>[^/]+)') {
        return "https://github.com/$($Matches.o)/$($Matches.r)"
    }
    return $null
}

function Convert-ToGitHubSsh {
    param([string]$Url)
    if ($Url -match '^https://github\.com/(?<o>[^/]+)/(?<r>[^/]+)') {
        return "git@github.com:$($Matches.o)/$($Matches.r).git"
    }
    return $Url.Trim().TrimEnd('/')
}

function Convert-ToGitLabSsh {
    param([Parameter(Mandatory)][string]$Url, [string]$SshUser = 'git')

    $u = $Url.Trim()
    if ($u -match '^(git@|ssh://)') { return $u }

    try {
        $uri  = [uri]$u
        $host = $uri.Host
        $path = $uri.AbsolutePath.Trim('/')
        if (-not $host -or -not $path) { return $u }
        $path = ($path -replace '\.git$','')
        return ("{0}@{1}:{2}.git" -f $SshUser, $host, $path)
    } catch {
        return $u
    }
}

function Get-UrlsModeSettings {
    switch ($UrlsMode) {
        'Default'       { @{ Sort=$false; Report=$false; Dedupe=$true  } }
        'Sort'          { @{ Sort=$true;  Report=$false; Dedupe=$true  } }
        'Report'        { @{ Sort=$false; Report=$true;  Dedupe=$true  } }
        'SortAndReport' { @{ Sort=$true;  Report=$true;  Dedupe=$true  } }
        'NoDedupe'      { @{ Sort=$false; Report=$false; Dedupe=$false } }
        default { throw "Invalid UrlsMode: $UrlsMode" }
    }
}

function Get-RepoModeSettings {
    switch ($RepoMode) {
        'Sync'       { @{ Clone=$true;  Update=$true;  ListOnly=$false } }
        'UpdateOnly' { @{ Clone=$false; Update=$true;  ListOnly=$false } }
        'CloneOnly'  { @{ Clone=$true;  Update=$false; ListOnly=$false } }
        'ListOnly'   { @{ Clone=$false; Update=$false; ListOnly=$true  } }
        default { throw "Invalid RepoMode: $RepoMode" }
    }
}

function Write-FileUtf8 {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string[]]$Lines)
    if ($PSVersionTable.PSVersion.Major -ge 7) { Set-Content -Path $Path -Value $Lines -Encoding utf8NoBOM }
    else { Set-Content -Path $Path -Value $Lines -Encoding UTF8 }
}

function Update-UrlsFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][hashtable]$Mode)

    if (-not (Test-Path -LiteralPath $Path)) { throw "urls file not found: $Path" }

    $raw = Get-Content -LiteralPath $Path
    $comments = $raw | Where-Object { $_ -match '^\s*#' }

    $urls = $raw |
        Where-Object { $_ -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    $fixed = foreach ($u in $urls) {
        if ($u -match '^https://github\.com/.+/.+/.+') {
            $root = Get-GitHubRepoRootWebUrl -Url $u
            if ($root) { $root } else { $u }
        } else { $u }
    }

    if ($Mode.Report) {
        $dups = $fixed | Group-Object { ConvertTo-NormalizedUrlKey $_ } | Where-Object Count -gt 1
        foreach ($d in $dups) {
            Write-Host "⚠ Duplicate URLs:" -ForegroundColor Yellow
            $d.Group | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        }
    }

    $forFile = if ($Mode.Sort) { $fixed | Sort-Object } else { $fixed }

    if ($Mode.Sort) {
        Write-FileUtf8 -Path $Path -Lines (@($comments) + @($forFile))
    }

    if ($Mode.Dedupe) {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        $unique = [System.Collections.Generic.List[string]]::new()
        foreach ($u in $forFile) {
            $k = ConvertTo-NormalizedUrlKey -Url $u
            if ($seen.Add($k)) { $null = $unique.Add($u) }
        }
        return $unique.ToArray()
    }

    return @($forFile)
}

function Test-InteractiveShell {
    try {
        if (-not $Host.UI -or -not $Host.UI.RawUI) { return $false }
        if ([System.Console]::IsOutputRedirected) { return $false }
        return $true
    } catch { return $false }
}

function Test-ProgressAllowed {
    if (-not (Test-InteractiveShell)) { return $false }
    if ($ProgressPreference -eq 'SilentlyContinue' -and -not $ForceProgressBarInShell) { return $false }
    return $true
}

function Normalize-BranchName {
    param([string]$Branch)
    if (-not $Branch) { return $null }
    $b = $Branch.Trim()
    $b = $b -replace '^refs/heads/',''
    $b = $b -replace '^heads/',''
    $b = $b -replace '^origin/',''
    if (-not $b) { return $null }
    return $b
}

function Get-RepoDirName {
    param([Parameter(Mandatory)][string]$RawUrl,[Parameter(Mandatory)][string]$CloneUrl,[Parameter(Mandatory)][bool]$IsGitLab)

    if (-not $IsGitLab -and $CloneUrl -match '^git@github\.com:(?<o>[^/]+)/(?<r>[^/]+)') {
        return ("{0}__{1}" -f (ConvertTo-SafePart $Matches.o),(ConvertTo-SafePart ($Matches.r -replace '\.git$','')))
    }

    if ($CloneUrl -match '^[^@]+@[^:]+:(?<p>.+?)(?:\.git)?$') {
        $parts = ($Matches.p -replace '\.git$','') -split '/'
        if ($parts.Count -ge 2) {
            return (($parts | ForEach-Object { ConvertTo-SafePart $_ }) -join '__')
        }
    }

    try {
        $uri = [uri]$RawUrl
        $parts = ($uri.AbsolutePath.Trim('/') -replace '\.git$','') -split '/'
        if ($parts.Count -ge 2) {
            return (($parts | ForEach-Object { ConvertTo-SafePart $_ }) -join '__')
        }
    } catch { }

    return (ConvertTo-SafePart (($CloneUrl -replace '.*/','') -replace '\.git$',''))
}

function Find-RepoFolderPath {
    param([Parameter(Mandatory)][string]$Parent,[Parameter(Mandatory)][string]$BaseName)

    $exact = Join-Path $Parent $BaseName
    if (Test-Path -LiteralPath $exact) { return $exact }

    $dirs = Get-ChildItem -LiteralPath $Parent -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$BaseName *" }

    $bestDir = $null
    $bestDt  = $null
    $escaped = [regex]::Escape($BaseName)

    foreach ($d in $dirs) {
        if ($d.Name -match ('^' + $escaped + '\s(?<ts>\d{8}-\d{4})(?:-\d{2})?$')) {
            try {
                $dt = [datetime]::ParseExact($Matches.ts, 'yyyyMMdd-HHmm', $null)
                if (-not $bestDt -or $dt -gt $bestDt) { $bestDt = $dt; $bestDir = $d.FullName }
            } catch { }
        }
    }
    return $bestDir
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$GitArgs,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$Tag = 'repo'
    )

    if (-not $GitArgs -or $GitArgs.Count -eq 0) {
        return [pscustomobject]@{ ExitCode = 1; StdOut=''; StdErr=@('BUG: empty GitArgs passed to Invoke-Git'); TimedOut=$false; ArgsText='' }
    }

    $safeTag = ($Tag -replace '[^\w\.-]','_')
    $id = [guid]::NewGuid().ToString('N')
    $out = Join-Path $env:TEMP ("git_{0}_{1}.out" -f $safeTag, $id)
    $err = Join-Path $env:TEMP ("git_{0}_{1}.err" -f $safeTag, $id)

    try {
        $p = Start-Process -FilePath git -ArgumentList $GitArgs -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
            -RedirectStandardOutput $out -RedirectStandardError $err
    } catch {
        return [pscustomobject]@{ ExitCode = 127; StdOut=''; StdErr=@($_.Exception.Message); TimedOut=$false; ArgsText=($GitArgs -join ' ') }
    }

    $start = Get-Date
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 200
        if (((Get-Date) - $start).TotalSeconds -ge $TimeoutSeconds) {
            Stop-ProcessTree -Pid $p.Id
            $stderr = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -ErrorAction SilentlyContinue } else { @() }
            $stdout = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue } else { '' }
            try { Remove-Item -LiteralPath $out,$err -ErrorAction SilentlyContinue } catch {}
            return [pscustomobject]@{ ExitCode=124; StdOut=$stdout; StdErr=$stderr; TimedOut=$true; ArgsText=($GitArgs -join ' ') }
        }
    }

    $exit = $p.ExitCode
    $stdout2 = if (Test-Path -LiteralPath $out) { (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) } else { '' }
    $stderr2 = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -ErrorAction SilentlyContinue } else { @() }
    try { Remove-Item -LiteralPath $out,$err -ErrorAction SilentlyContinue } catch {}

    [pscustomobject]@{ ExitCode=$exit; StdOut=$stdout2; StdErr=$stderr2; TimedOut=$false; ArgsText=($GitArgs -join ' ') }
}

function Remove-StaleIndexLock {
    param([Parameter(Mandatory)][string]$RepoPath,[int]$StaleMinutes = 10)
    $lockPath = Join-Path $RepoPath '.git\index.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { return $false }
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
        if ($age.TotalMinutes -lt $StaleMinutes) { return $false }
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

# ---------------------- Worker (runspaces do not inherit funcs) -------

$worker = {
    param($Item, $Shared)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $env:GIT_TERMINAL_PROMPT = '0'
    if ($Shared.GitSshCommand) { $env:GIT_SSH_COMMAND = [string]$Shared.GitSshCommand }

    function Stop-ProcessTreeLocal {
        param([int]$Pid)
        if ($env:OS -eq 'Windows_NT') { try { & taskkill.exe /PID $Pid /T /F | Out-Null } catch { } }
        else { try { Stop-Process -Id $Pid -Force -ErrorAction SilentlyContinue } catch { } }
    }

    function Invoke-GitLocal {
        param([string]$WorkingDirectory,[string[]]$GitArgs,[int]$TimeoutSeconds,[string]$Tag)

        if (-not $GitArgs -or $GitArgs.Count -eq 0) {
            return [pscustomobject]@{ ExitCode = 1; StdOut=''; StdErr=@('BUG: empty GitArgs passed to Invoke-GitLocal'); TimedOut=$false; ArgsText='' }
        }

        $safeTag = ($Tag -replace '[^\w\.-]','_')
        $id = [guid]::NewGuid().ToString('N')
        $out = Join-Path $env:TEMP ("git_{0}_{1}.out" -f $safeTag, $id)
        $err = Join-Path $env:TEMP ("git_{0}_{1}.err" -f $safeTag, $id)

        try {
            $p = Start-Process -FilePath git -ArgumentList $GitArgs -WorkingDirectory $WorkingDirectory -NoNewWindow -PassThru `
                -RedirectStandardOutput $out -RedirectStandardError $err
        } catch {
            return [pscustomobject]@{ ExitCode=127; StdOut=''; StdErr=@($_.Exception.Message); TimedOut=$false; ArgsText=($GitArgs -join ' ') }
        }

        $start = Get-Date
        while (-not $p.HasExited) {
            Start-Sleep -Milliseconds 200
            if (((Get-Date) - $start).TotalSeconds -ge $TimeoutSeconds) {
                Stop-ProcessTreeLocal -Pid $p.Id
                $stderr = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -ErrorAction SilentlyContinue } else { @() }
                $stdout = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue } else { '' }
                try { Remove-Item -LiteralPath $out,$err -ErrorAction SilentlyContinue } catch {}
                return [pscustomobject]@{ ExitCode=124; StdOut=$stdout; StdErr=$stderr; TimedOut=$true; ArgsText=($GitArgs -join ' ') }
            }
        }

        $exit = $p.ExitCode
        $stdout2 = if (Test-Path -LiteralPath $out) { (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) } else { '' }
        $stderr2 = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -ErrorAction SilentlyContinue } else { @() }
        try { Remove-Item -LiteralPath $out,$err -ErrorAction SilentlyContinue } catch {}
        [pscustomobject]@{ ExitCode=$exit; StdOut=$stdout2; StdErr=$stderr2; TimedOut=$false; ArgsText=($GitArgs -join ' ') }
    }

    function Normalize-BranchNameLocal {
        param([string]$Branch)
        if (-not $Branch) { return $null }
        $b = $Branch.Trim()
        $b = $b -replace '^refs/heads/',''
        $b = $b -replace '^heads/',''
        $b = $b -replace '^origin/',''
        if (-not $b) { return $null }
        return $b
    }

    function Remove-StaleIndexLockLocal {
        param([string]$RepoPath,[int]$StaleMinutes)
        $lockPath = Join-Path $RepoPath '.git\index.lock'
        if (-not (Test-Path -LiteralPath $lockPath)) { return $false }
        try {
            $age = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
            if ($age.TotalMinutes -lt $StaleMinutes) { return $false }
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction Stop
            return $true
        } catch { return $false }
    }

    $t0 = Get-Date
    $tag = $Item.BaseName

    try {
        if ($Shared.RepoSettings.ListOnly) {
            return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Skipped'; Message='ListOnly'; Duration=((Get-Date)-$t0).TotalSeconds }
        }

        if (Test-Path -LiteralPath $Item.RepoPath) {

            if (-not (Test-Path -LiteralPath (Join-Path $Item.RepoPath '.git'))) {
                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Error'; Message='Folder exists but is not a git repo (.git missing).'; Duration=((Get-Date)-$t0).TotalSeconds }
            }

            if (-not $Shared.RepoSettings.Update) {
                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Skipped'; Message='Update disabled'; Duration=((Get-Date)-$t0).TotalSeconds }
            }

            # Align origin
            $origin = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('remote','get-url','origin') -TimeoutSeconds 30 -Tag $tag
            if ($origin.ExitCode -eq 0) {
                $cur = $origin.StdOut.Trim()
                if ($cur -and $cur -ne $Item.CloneUrl) {
                    $null = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('remote','set-url','origin',$Item.CloneUrl) -TimeoutSeconds 30 -Tag $tag
                }
            }

            # Fetch w/ lock retry
            $attempt = 0
            while ($true) {
                $attempt++
                $f = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs (@('fetch','--all','--prune') + $Shared.GitNoProgressArgs) -TimeoutSeconds $Shared.FetchTimeoutSeconds -Tag $tag
                if ($f.ExitCode -eq 0) { break }

                $msg = (($f.StdErr + @($f.StdOut)) -join "`n").Trim()
                $isLock = $msg -match 'index\.lock' -and $msg -match 'File exists'
                if ($Shared.AutoFixIndexLock -and $isLock -and $attempt -le ($Shared.LockRetryCount + 1)) {
                    if (Remove-StaleIndexLockLocal -RepoPath $Item.RepoPath -StaleMinutes $Shared.LockStaleMinutes) { continue }
                }
                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Error'; Message=("git failed (exit {0}): git {1}`n{2}" -f $f.ExitCode, $f.ArgsText, $msg); Duration=((Get-Date)-$t0).TotalSeconds }
            }

            # Determine branch
            $branch = $null
            $b1 = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('symbolic-ref','--short','HEAD') -TimeoutSeconds 30 -Tag $tag
            if ($b1.ExitCode -eq 0 -and $b1.StdOut) { $branch = Normalize-BranchNameLocal -Branch $b1.StdOut }
            if (-not $branch) {
                $b2 = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('symbolic-ref','--quiet','--short','refs/remotes/origin/HEAD') -TimeoutSeconds 30 -Tag $tag
                if ($b2.ExitCode -eq 0 -and $b2.StdOut) {
                    $tmp = $b2.StdOut.Trim()
                    if ($tmp -match '^origin/(?<b>.+)$') { $branch = Normalize-BranchNameLocal -Branch $Matches.b }
                    else { $branch = Normalize-BranchNameLocal -Branch $tmp }
                }
            }
            if (-not $branch) {
                foreach ($c in @('main','master')) {
                    $chk = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('show-ref','--verify','--quiet',("refs/remotes/origin/{0}" -f $c)) -TimeoutSeconds 30 -Tag $tag
                    if ($chk.ExitCode -eq 0) { $branch = $c; break }
                }
            }
            if (-not $branch) {
                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Unchanged'; Message='No default branch detected'; Duration=((Get-Date)-$t0).TotalSeconds }
            }

            # Compare trees (FIXED)
            $lt = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('rev-parse','HEAD^{tree}') -TimeoutSeconds 30 -Tag $tag
            $rt = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('rev-parse', "origin/$branch^{tree}") -TimeoutSeconds 30 -Tag $tag

            $ltt = $lt.StdOut.Trim()
            $rtt = $rt.StdOut.Trim()

            if ($lt.ExitCode -ne 0 -or $rt.ExitCode -ne 0 -or -not $ltt -or -not $rtt) {
                $diag = "ltExit=$($lt.ExitCode) rtExit=$($rt.ExitCode) lt='$ltt' rt='$rtt'"
                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Error'; Message=("Unable to resolve tree IDs. {0}" -f $diag); Duration=((Get-Date)-$t0).TotalSeconds }
            }

            if ($ltt -ne $rtt) {
                # Reset w/ lock retry (FIXED)
                $attempt = 0
                while ($true) {
                    $attempt++
                    $r2 = Invoke-GitLocal -WorkingDirectory $Item.RepoPath -GitArgs @('reset','--hard', "origin/$branch") -TimeoutSeconds $Shared.ResetTimeoutSeconds -Tag $tag
                    if ($r2.ExitCode -eq 0) { break }

                    $msg2 = (($r2.StdErr + @($r2.StdOut)) -join "`n").Trim()
                    $isLock2 = $msg2 -match 'index\.lock' -and $msg2 -match 'File exists'
                    if ($Shared.AutoFixIndexLock -and $isLock2 -and $attempt -le ($Shared.LockRetryCount + 1)) {
                        if (Remove-StaleIndexLockLocal -RepoPath $Item.RepoPath -StaleMinutes $Shared.LockStaleMinutes) { continue }
                    }
                    return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Error'; Message=("git failed (exit {0}): git {1}`n{2}" -f $r2.ExitCode, $r2.ArgsText, $msg2); Duration=((Get-Date)-$t0).TotalSeconds }
                }

                if ($Shared.RenameOnUpdate) {
                    $parent = Split-Path -Parent $Item.RepoPath
                    $stamp  = (Get-Date).ToString($Shared.RenameFormat)
                    $newBase = $Item.BaseName + $Shared.RenameSeparator + $stamp

                    $newName = $newBase
                    if (Test-Path -LiteralPath (Join-Path $parent $newName)) {
                        for ($i=1; $i -le 99; $i++) {
                            $try = "{0}-{1:D2}" -f $newBase, $i
                            if (-not (Test-Path -LiteralPath (Join-Path $parent $try))) { $newName = $try; break }
                        }
                    }

                    Rename-Item -LiteralPath $Item.RepoPath -NewName $newName -ErrorAction Stop
                    return [pscustomobject]@{ Dir=$newName; Status='Updated'; Message='Updated + renamed'; Duration=((Get-Date)-$t0).TotalSeconds }
                }

                return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Updated'; Message='Updated'; Duration=((Get-Date)-$t0).TotalSeconds }
            }

            return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Unchanged'; Message='Up to date'; Duration=((Get-Date)-$t0).TotalSeconds }
        }

        # Clone
        if (-not $Shared.RepoSettings.Clone) {
            return [pscustomobject]@{ Dir=$Item.BaseName; Status='Skipped'; Message='Clone disabled'; Duration=((Get-Date)-$t0).TotalSeconds }
        }

        $c = Invoke-GitLocal -WorkingDirectory $Shared.ScriptDirectory -GitArgs (@('clone') + $Shared.GitNoProgressArgs + @($Item.CloneUrl, $Item.BaseName)) -TimeoutSeconds $Shared.CloneTimeoutSeconds -Tag $tag
        if ($c.ExitCode -ne 0) {
            $msgc = (($c.StdErr + @($c.StdOut)) -join "`n").Trim()
            return [pscustomobject]@{ Dir=$Item.BaseName; Status='Error'; Message=("git failed (exit {0}): git {1}`n{2}" -f $c.ExitCode, $c.ArgsText, $msgc); Duration=((Get-Date)-$t0).TotalSeconds }
        }

        return [pscustomobject]@{ Dir=$Item.BaseName; Status='Cloned'; Message='Cloned'; Duration=((Get-Date)-$t0).TotalSeconds }
    }
    catch {
        return [pscustomobject]@{ Dir=$Item.DisplayName; Status='Error'; Message=$_.Exception.Message; Duration=((Get-Date)-$t0).TotalSeconds }
    }
}

# -------------------- Parallel runner (runspace pool) -----------------

function Invoke-Parallel {
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [Parameter(Mandatory)][scriptblock]$Worker,
        [Parameter(Mandatory)][hashtable]$Shared,
        [Parameter(Mandatory)][int]$Throttle
    )

    $progressAllowed = Test-ProgressAllowed
    $total = $Items.Count
    if ($total -eq 0) { return @() }

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $Throttle)
    $pool.Open()

    $running = New-Object System.Collections.Generic.List[object]
    $results = New-Object System.Collections.Generic.List[object]

    $idx = 0
    $completed = 0
    $lastUi = Get-Date
    $lastBeat = Get-Date
    $lastCompletedName = ''

    $oldProgress = $ProgressPreference
    if ($progressAllowed -and $ForceProgressBarInShell) { $ProgressPreference = 'Continue' }

    function Start-One {
        param([object]$Item)
        if ($ShowRepoStartLines) {
            Write-Host ("▶ Checking: {0}" -f $Item.DisplayName) -ForegroundColor DarkGray
        }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($Worker).AddArgument($Item).AddArgument($Shared)
        $handle = $ps.BeginInvoke()
        $running.Add([pscustomobject]@{ PS=$ps; Handle=$handle; Item=$Item; StartTime=(Get-Date) }) | Out-Null
    }

    try {
        while ($completed -lt $total) {

            while ($idx -lt $total -and $running.Count -lt $Throttle) {
                Start-One -Item $Items[$idx]
                $idx++
            }

            for ($i = $running.Count - 1; $i -ge 0; $i--) {
                $job = $running[$i]
                $age = (Get-Date) - $job.StartTime

                if (-not $job.Handle.IsCompleted -and $age.TotalSeconds -ge $Shared.PerRepoRunspaceMaxSeconds) {
                    try { $job.PS.Stop() } catch {}
                    try { $job.PS.Dispose() } catch {}
                    $results.Add([pscustomobject]@{
                        Dir=$job.Item.DisplayName; Status='Error';
                        Message=("Runspace max exceeded ({0}s)." -f $Shared.PerRepoRunspaceMaxSeconds);
                        Duration=$age.TotalSeconds
                    }) | Out-Null
                    $running.RemoveAt($i)
                    $completed++
                    continue
                }

                if ($job.Handle.IsCompleted) {
                    $out = $null
                    try { $out = $job.PS.EndInvoke($job.Handle) } catch {
                        $out = @([pscustomobject]@{ Dir=$job.Item.DisplayName; Status='Error'; Message=$_.Exception.Message; Duration=$age.TotalSeconds })
                    }

                    foreach ($o in @($out)) {
                        $results.Add($o) | Out-Null
                        if ($ShowPerRepoStatus) {
                            $lastCompletedName = $o.Dir
                            $dur = [math]::Round([double]$o.Duration, 1)
                            switch ($o.Status) {
                                'Cloned'    { Write-Host ("📥 Cloned   : {0} ({1}s)" -f $o.Dir, $dur) -ForegroundColor Green }
                                'Updated'   { Write-Host ("⬆ Updated  : {0} ({1}s)" -f $o.Dir, $dur) -ForegroundColor Cyan }
                                'Unchanged' { Write-Host ("✅ Unchanged: {0} ({1}s)" -f $o.Dir, $dur) -ForegroundColor DarkGreen }
                                'Skipped'   { Write-Host ("⏭ Skipped  : {0} ({1}s)" -f $o.Dir, $dur) -ForegroundColor DarkYellow }
                                'Error'     { Write-Host ("❌ Error    : {0} ({1}s)" -f $o.Dir, $dur) -ForegroundColor Red; Write-Host ("    " + $o.Message) -ForegroundColor Red }
                                default     { Write-Host ("• {0}: {1} ({2}s)" -f $o.Status, $o.Dir, $dur) -ForegroundColor DarkGray }
                            }
                        }
                    }

                    try { $job.PS.Dispose() } catch {}
                    $running.RemoveAt($i)
                    $completed++
                }
            }

            $now = Get-Date
            if (($now - $lastUi).TotalMilliseconds -ge $ProgressUpdateMs) {
                $lastUi = $now
                if ($progressAllowed) {
                    $pct = ($completed / $total * 100)
                    $status = "Done $completed/$total | Throttle $Throttle"
                    if ($lastCompletedName) { $status += " | Last: $lastCompletedName" }
                    Write-Progress -Activity "Syncing repositories" -Status $status -PercentComplete $pct
                }
            }

            if (($now - $lastBeat).TotalSeconds -ge $HeartbeatSeconds -and $running.Count -gt 0) {
                $lastBeat = $now
                $top = $running | Sort-Object { ((Get-Date) - $_.StartTime).TotalSeconds } -Descending | Select-Object -First 5
                Write-Host ("[heartbeat] in-flight={0} | longest:" -f $running.Count) -ForegroundColor DarkGray
                foreach ($j in $top) {
                    $a = [math]::Round(((Get-Date) - $j.StartTime).TotalSeconds, 1)
                    Write-Host ("    - {0} ({1}s)" -f $j.Item.DisplayName, $a) -ForegroundColor DarkGray
                }
            }

            Start-Sleep -Milliseconds 120
        }

        if ($progressAllowed) { Write-Progress -Activity "Syncing repositories" -Completed }
        return $results.ToArray()
    }
    finally {
        try { $ProgressPreference = $oldProgress } catch {}
        foreach ($job in $running) { try { $job.PS.Stop() } catch {}; try { $job.PS.Dispose() } catch {} }
        try { $pool.Close() } catch {}
        try { $pool.Dispose() } catch {}
    }
}

# ---------------------- Startup --------------------------------------

$urlsSettings = Get-UrlsModeSettings
$repoSettings = Get-RepoModeSettings

$sshCmd = Get-SshCommand
if ($sshCmd) { $env:GIT_SSH_COMMAND = $sshCmd }

Write-Host "UrlsMode: $UrlsMode | RepoMode: $RepoMode | DebugFailures: $DebugFailures" -ForegroundColor DarkGray
Write-Host ("Parallel: {0} | FixedThrottle: {1} | RepoRunspaceMax: {2}s | Heartbeat: {3}s" -f $UseParallel, $FixedThrottle, $PerRepoRunspaceMaxSeconds, $HeartbeatSeconds) -ForegroundColor DarkGray
Write-Host ("SSH: BatchMode={0} | AcceptNewHostKeys={1} | ConnectTimeout={2} | Alive={3}/{4}" -f $ForceSshBatchMode, $AcceptNewHostKeys, $SshConnectTimeout, $SshServerAliveInt, $SshServerAliveCount) -ForegroundColor DarkGray
Write-Host ""

$UrlsFile = Join-Path $ScriptDirectory 'urls.txt'
$UrlsToProcess = Update-UrlsFile -Path $UrlsFile -Mode $urlsSettings

$workItems = foreach ($RawUrl in $UrlsToProcess) {
    $isGitLab = Test-IsGitLabUrl $RawUrl
    $cloneUrl = if ($isGitLab) {
        if ($GitLabTransport -eq 'SSH') { Convert-ToGitLabSsh -Url $RawUrl -SshUser $GitLabSshUser }
        else { ($RawUrl.TrimEnd('/') -replace '\.git$','') + '.git' }
    } else {
        Convert-ToGitHubSsh $RawUrl
    }

    $baseName  = Get-RepoDirName -RawUrl $RawUrl -CloneUrl $cloneUrl -IsGitLab $isGitLab
    $foundPath = Find-RepoFolderPath -Parent $ScriptDirectory -BaseName $baseName
    $repoPath  = if ($foundPath) { $foundPath } else { Join-Path $ScriptDirectory $baseName }

    [pscustomobject]@{
        RawUrl      = $RawUrl
        IsGitLab    = $isGitLab
        CloneUrl    = $cloneUrl
        BaseName    = $baseName
        RepoPath    = $repoPath
        DisplayName = (Split-Path -Leaf $repoPath)
    }
}

$TotalRepos = $workItems.Count

$shared = @{
    RepoSettings              = $repoSettings
    ScriptDirectory           = $ScriptDirectory
    GitNoProgressArgs         = $GitNoProgressArgs
    DebugFailures             = $DebugFailures

    FetchTimeoutSeconds       = $FetchTimeoutSeconds
    ResetTimeoutSeconds       = $ResetTimeoutSeconds
    CloneTimeoutSeconds       = $CloneTimeoutSeconds
    PerRepoRunspaceMaxSeconds = $PerRepoRunspaceMaxSeconds

    RenameOnUpdate            = $RenameOnUpdate
    RenameFormat              = $RenameFormat
    RenameSeparator           = $RenameSeparator

    GitSshCommand             = $env:GIT_SSH_COMMAND

    AutoFixIndexLock          = $AutoFixIndexLock
    LockStaleMinutes          = $LockStaleMinutes
    LockRetryCount            = $LockRetryCount
}

Write-Host "Running parallel..." -ForegroundColor DarkGray
$results = if ($UseParallel) {
    Invoke-Parallel -Items $workItems -Worker $worker -Shared $shared -Throttle $FixedThrottle
} else {
    foreach ($item in $workItems) { & $worker $item $shared }
}

foreach ($r in $results) {
    switch ($r.Status) {
        'Cloned'    { $ClonedRepos++ }
        'Updated'   { $UpdatedRepos++ }
        'Unchanged' { $UnchangedRepos++ }
        'Skipped'   { $SkippedRepos++ }
        'Error'     { $ErrorRepos++ }
        default     { $SkippedRepos++ }
    }
}

Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
Write-Host "Processed : $TotalRepos"
Write-Host "Cloned    : $ClonedRepos"
Write-Host "Updated   : $UpdatedRepos"
Write-Host "Unchanged : $UnchangedRepos"
Write-Host "Skipped   : $SkippedRepos"
Write-Host "Errors    : $ErrorRepos"
Write-Host "============================"

Set-Location $InitialDirectory
