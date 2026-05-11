#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ===================== Config =====================

# Folder used when the dialog opens (if it exists). Otherwise uses current directory.
$DefaultFolder = "C:\Hard\Coded\Path\Here"

# Debug prints
$EnableDebug = $true

# Chunk size for Excel writes (performance)
$WriteChunkSize = 5000

# CombinedData filter:
#   'All'      -> all findings rows
#   'IPv4Only' -> only rows where IP column contains a literal IPv4 (default)
$CombinedDataFilterMode = 'IPv4Only'

# Only relevant when CombinedDataFilterMode isn't 'All'
$IncludeHostnameOnlyRows = $false

#endregion

#region ===================== Bootstrap (Windows + STA) =====================

$OnWindows = $true
if ($PSVersionTable.PSVersion.Major -ge 6) { $OnWindows = [bool]$IsWindows }
if (-not $OnWindows) { throw "This script requires Windows (WinForms + Excel COM)." }

try { $apt = [System.Threading.Thread]::CurrentThread.ApartmentState } catch { $apt = 'Unknown' }
if ($apt -ne 'STA') {
    Write-Host "Not running in STA. Relaunching in STA..." -ForegroundColor Yellow
    if (-not $PSCommandPath) { throw "Save this script to a .ps1 file before running." }

    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Sta','-File',$PSCommandPath) | Out-Null
    return
}

Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles() | Out-Null

#endregion

#region ===================== File Lock / Overwrite Helpers =====================

function Test-FileLocked {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $fs.Close()
        return $false
    } catch {
        return $true
    }
}

# prompt only once per run
$script:OverwritePrompted = $false
$script:OverwriteApproved = $false

function Ensure-OutputPathIsSafeOrExit {
    <#
      If SavePath exists:
        - Prompt overwrite ONCE per run
        - Attempt to delete
        - Retry briefly (OneDrive/AV transient handles)
        - If still locked, tell user to close and re-run, then exit
      IMPORTANT: Does NOT attempt to close Excel/workbooks.
    #>
    param([Parameter(Mandatory)][string]$SavePath)

    if (-not (Test-Path -LiteralPath $SavePath)) { return }

    if (-not $script:OverwritePrompted) {
        $script:OverwritePrompted = $true
        $resp = [System.Windows.Forms.MessageBox]::Show(
            "The file already exists:`n`n$SavePath`n`nOverwrite it?",
            "Overwrite Output File",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        $script:OverwriteApproved = ($resp -eq [System.Windows.Forms.DialogResult]::Yes)
        if (-not $script:OverwriteApproved) {
            throw "User chose not to overwrite existing file: $SavePath"
        }
    }

    $full = [System.IO.Path]::GetFullPath($SavePath)

    # first attempt
    try {
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        return
    } catch { }

    # transient retry loop
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        Start-Sleep -Milliseconds 250
        try {
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            return
        } catch { }
    }

    if (Test-FileLocked -Path $full) {
        [System.Windows.Forms.MessageBox]::Show(
            "The output workbook appears to be open or locked:`n`n$full`n`nPlease close it and re-run the script.",
            "File In Use",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        throw "Output file is open/locked. User must close and re-run: $full"
    }

    throw "Unable to delete existing output file (not a lock). Check permissions: $full"
}

#endregion

#region ===================== Input Selection (Single Dialog: file(s) OR folder) =====================

function Select-CsvInputSingleDialog {
    <#
      ONE DIALOG ONLY:
        - Select 1+ CSV files -> use them
        - Browse to folder, select NO files, click Open -> use all *.csv in that folder (non-recursive)
        - Cancel -> use all *.csv in PowerShell current directory (non-recursive)
    #>
    param(
        [string]$InitialFolder
    )

    if (-not $InitialFolder -or -not (Test-Path -LiteralPath $InitialFolder -PathType Container)) {
        $InitialFolder = (Get-Location).Path
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Select CSV file(s) OR browse to a folder and click Open (no selection = use folder)"
    $ofd.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $ofd.Multiselect = $true

    # Folder-capable mode:
    $ofd.ValidateNames   = $false
    $ofd.CheckFileExists = $false
    $ofd.CheckPathExists = $true

    # Dummy filename so Open is enabled even without selecting a real file
    $ofd.FileName = "Select this folder"
    $ofd.InitialDirectory = $InitialFolder

    $result = $ofd.ShowDialog()

    # Cancel -> use current PowerShell directory (non-recursive)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        $folder = (Get-Location).Path
        $csvs = @(Get-ChildItem -LiteralPath $folder -Filter *.csv -File | Sort-Object Name)
        if ($csvs.Count -eq 0) { throw "No CSV files found in current directory: $folder" }
        return [pscustomobject]@{ Folder = $folder; CsvFiles = $csvs }
    }

    # Any explicitly selected CSV files?
    $selectedCsvPaths = @(
        @($ofd.FileNames) |
            Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Where-Object { [System.IO.Path]::GetExtension($_) -ieq '.csv' }
    )

    if ($selectedCsvPaths.Count -gt 0) {
        $files = @($selectedCsvPaths | ForEach-Object { Get-Item -LiteralPath $_ })
        return [pscustomobject]@{ Folder = $files[0].DirectoryName; CsvFiles = $files }
    }

    # OK but no CSVs selected -> use folder currently shown (derived from FileName)
    $folderFromDialog = [System.IO.Path]::GetDirectoryName($ofd.FileName)
    if (-not $folderFromDialog -or -not (Test-Path -LiteralPath $folderFromDialog -PathType Container)) {
        $folderFromDialog = $ofd.InitialDirectory
    }

    $csvs = @(Get-ChildItem -LiteralPath $folderFromDialog -Filter *.csv -File | Sort-Object Name)
    if ($csvs.Count -eq 0) { throw "No CSV files found in selected folder: $folderFromDialog" }

    return [pscustomobject]@{ Folder = $folderFromDialog; CsvFiles = $csvs }
}

#endregion

#region ===================== Excel + Data Helpers =====================

function New-2DObjectArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Rows,
        [Parameter(Mandatory)][int]$Cols,
        [string]$Name = 'Matrix'
    )

    if ($Rows -le 0 -or $Cols -le 0) {
        throw "$Name creation failed: Rows/Cols must be > 0 (Rows=$Rows Cols=$Cols)"
    }

    $a = [System.Array]::CreateInstance([object], [int]$Rows, [int]$Cols)
    if ($null -eq $a) { throw "$Name creation failed: null (Rows=$Rows Cols=$Cols)" }
    if ($a.Rank -ne 2) { throw "$Name is not 2D. Type=$($a.GetType().FullName) Rank=$($a.Rank)" }

    # Prevent PS enumerating 2D arrays into 1D
    return ,$a
}

function ConvertTo-SafeSheetName {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$Workbook)

    if ($null -eq $Name) { $Name = "" }

    $n = $Name.Trim()
    $n = $n -replace '[:\\\/\?\*\[\]]', '_'
    if ([string]::IsNullOrWhiteSpace($n)) { $n = "Sheet" }
    if ($n.Length -gt 31) { $n = $n.Substring(0,31) }

    $base = $n
    $i = 1
    while ($true) {
        $exists = $false
        for ($s = 1; $s -le $Workbook.Sheets.Count; $s++) {
            if ($Workbook.Sheets.Item($s).Name -eq $n) { $exists = $true; break }
        }
        if (-not $exists) { return $n }

        $suffix = "_$i"
        $maxBase = [Math]::Max(1, 31 - $suffix.Length)
        $n = ($base.Substring(0, [Math]::Min($base.Length, $maxBase))) + $suffix
        $i++
        if ($i -gt 999) { return ("Sheet_" + ([Guid]::NewGuid().ToString("N").Substring(0,8))) }
    }
}

function Add-WorksheetAfterLast {
    param([Parameter(Mandatory)][object]$Workbook)
    $missing = [System.Reflection.Missing]::Value
    $after = $Workbook.Sheets.Item($Workbook.Sheets.Count)
    return $Workbook.Worksheets.Add($missing, $after)
}

function Write-MatrixToExcel {
    param(
        [Parameter(Mandatory)][object]$Worksheet,
        [Parameter(Mandatory)][int]$StartRow1,
        [Parameter(Mandatory)][int]$StartCol1,
        [Parameter(Mandatory)][object]$Matrix,
        [Parameter(Mandatory)][int]$Rows,
        [Parameter(Mandatory)][int]$Cols,
        [string]$Context = ''
    )

    if ($null -eq $Worksheet) { throw "Write-MatrixToExcel: Worksheet is null. $Context" }
    if ($null -eq $Matrix)    { throw "Write-MatrixToExcel: Matrix is null. $Context Rows=$Rows Cols=$Cols" }
    if ($Matrix -isnot [System.Array] -or $Matrix.Rank -ne 2) {
        throw "Write-MatrixToExcel: Matrix not 2D. Type=$($Matrix.GetType().FullName) Rank=$($Matrix.Rank) $Context"
    }

    $range = $Worksheet.Cells.Item($StartRow1, $StartCol1).Resize($Rows, $Cols)
    $range.Value2 = $Matrix
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($range) } catch {}
}

function Set-WorksheetDefaultRowHeightNoWrap {
    param([Parameter(Mandatory)][object]$Worksheet)
    # CSV worksheets: keep default height, prevent expansion from newlines
    try { $Worksheet.Cells.WrapText = $false } catch {}
    try { $Worksheet.Rows.RowHeight = $Worksheet.StandardHeight } catch {}
}

function Remove-LeftoverDefaultSheets {
    param([Parameter(Mandatory)][object]$Workbook)
    for ($i = $Workbook.Sheets.Count; $i -ge 1; $i--) {
        $s = $Workbook.Sheets.Item($i)
        if ([string]$s.Name -match '^Sheet\d+$') {
            try { [void]$s.Delete() } catch {}
        }
    }
}

function Get-IPv4FromText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    if ($Value -match '(\d{1,3}(?:\.\d{1,3}){3})') {
        $ip = $Matches[1]
        $parts = $ip.Split('.')
        if ($parts.Count -ne 4) { return $null }
        foreach ($p in $parts) {
            $n = $p -as [int]
            if ($null -eq $n -or $n -lt 0 -or $n -gt 255) { return $null }
        }
        return $ip
    }
    return $null
}

function Apply-CombinedDataPostProcessing {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Worksheet)

    # Header bold + centered
    $xlCenter = -4108
    try {
        $hdrRow = $Worksheet.Rows.Item(1)
        $hdrRow.Font.Bold = $true
        $hdrRow.HorizontalAlignment = $xlCenter
    } catch {
        Write-Warning ("Header formatting failed: {0}" -f $_.Exception.Message)
    }

    # Hide column B
    try { $Worksheet.Columns.Item(2).Hidden = $true } catch {
        Write-Warning ("Failed to hide column B: {0}" -f $_.Exception.Message)
    }

    # Delete columns C,D,E,L,M,N,O,P,R,T,U,W,X,Y (right-to-left)
    $colsToDelete = @(25,24,23,21,20,18,16,15,14,13,12,5,4,3)
    try {
        $usedCols = [int]$Worksheet.UsedRange.Columns.Count
        foreach ($col in $colsToDelete) {
            if ($col -le $usedCols) {
                [void]$Worksheet.Columns.Item([int]$col).Delete()
                $usedCols--
            }
        }
    } catch {
        Write-Warning ("Column deletion failed: {0}" -f $_.Exception.Message)
    }

    # AutoFit all columns except D(4), I(9), J(10), K(11)
    $fixedCols = @(4,9,10,11)

    try {
        $usedCols = [int]$Worksheet.UsedRange.Columns.Count
        for ($c = 1; $c -le $usedCols; $c++) {
            if ($fixedCols -contains $c) { continue }
            try { $Worksheet.Columns.Item($c).AutoFit() | Out-Null } catch {}
        }
    } catch {
        Write-Warning ("AutoFit columns failed: {0}" -f $_.Exception.Message)
    }

    foreach ($c in $fixedCols) {
        try {
            if ([int]$Worksheet.UsedRange.Columns.Count -lt $c) { continue }
            $colObj = $Worksheet.Columns.Item($c)
            $colObj.ColumnWidth = 50
            $colObj.WrapText = $true
        } catch {
            Write-Warning ("Failed to set width/wrap on column index {0}: {1}" -f $c, $_.Exception.Message)
        }
    }

    # AutoFit rows after wrap
    try { $Worksheet.UsedRange.Rows.AutoFit() | Out-Null } catch {
        Write-Warning ("AutoFit rows failed: {0}" -f $_.Exception.Message)
    }
}

#endregion

#region ===================== CSV Parsing =====================

function Parse-FullCsvPreserveAllLines {
    <#
      Parses the entire export (metadata + blocks + findings + orphan lines) with TextFieldParser.
      Comma-delimited, quote-aware, supports embedded newlines inside quoted fields.
      Returns: MaxCols, Rows(List[object[]])
    #>
    param([Parameter(Mandatory)][string]$Path)

    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path)
    $p.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $p.SetDelimiters(@(','))
    $p.HasFieldsEnclosedInQuotes = $true

    try {
        $rows = New-Object 'System.Collections.Generic.List[object[]]'
        $maxCols = 0

        while (-not $p.EndOfData) {
            $fields = $p.ReadFields()
            if ($null -eq $fields) { continue }

            if ($fields.Length -gt $maxCols) { $maxCols = $fields.Length }

            $row = New-Object object[] $fields.Length
            for ($i=0; $i -lt $fields.Length; $i++) { $row[$i] = $fields[$i] }
            $rows.Add($row) | Out-Null
        }

        if ($maxCols -le 0) { return [pscustomobject]@{ MaxCols = 0; Rows = $rows } }

        # pad rows to maxCols
        for ($r=0; $r -lt $rows.Count; $r++) {
            $cur = $rows[$r]
            if ($cur.Length -lt $maxCols) {
                $pad = New-Object object[] $maxCols
                for ($i=0; $i -lt $cur.Length; $i++) { $pad[$i] = $cur[$i] }
                $rows[$r] = $pad
            }
        }

        return [pscustomobject]@{ MaxCols = $maxCols; Rows = $rows }
    }
    finally {
        $p.Close()
        $p.Dispose()
    }
}

function Find-QualysHeaderIndex0 {
    param([Parameter(Mandatory)][string]$Path, [int]$MaxScanLines = 2000)

    $needles = @('"IP"','"QID"','"Title"','"Severity"','"Results"','"Category"')
    $i = 0
    foreach ($line in Get-Content -LiteralPath $Path -TotalCount $MaxScanLines) {
        $ok = $true
        foreach ($n in $needles) {
            if ($line -notlike "*$n*") { $ok = $false; break }
        }
        if ($ok) { return $i }
        $i++
    }
    return -1
}

function Parse-QualysFindingsSection {
    param([Parameter(Mandatory)][string]$Path)

    $headerIdx0 = Find-QualysHeaderIndex0 -Path $Path
    if ($headerIdx0 -lt 0) { throw "Could not locate findings header in: $Path" }

    Add-Type -AssemblyName Microsoft.VisualBasic | Out-Null
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path)
    $p.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $p.SetDelimiters(@(','))
    $p.HasFieldsEnclosedInQuotes = $true

    try {
        for ($i=0; $i -lt $headerIdx0; $i++) { [void]$p.ReadLine() }

        $headers = $p.ReadFields()
        $expected = $headers.Length
        $resultsIdx = [Array]::IndexOf($headers, 'Results')
        if ($resultsIdx -lt 0) { $resultsIdx = $expected - 1 }

        $rows = New-Object 'System.Collections.Generic.List[object[]]'
        $current = $null

        while (-not $p.EndOfData) {
            $fields = $p.ReadFields()
            if (-not $fields) { continue }

            if ($fields.Length -eq $expected) {
                $row = New-Object object[] $expected
                for ($c=0; $c -lt $expected; $c++) { $row[$c] = $fields[$c] }
                $rows.Add($row) | Out-Null
                $current = $row
                continue
            }

            if ($current -ne $null -and $fields.Length -le 5) {
                $txt = ($fields -join ',')
                if (-not [string]::IsNullOrWhiteSpace($txt)) {
                    $prev = [string]$current[$resultsIdx]
                    if ([string]::IsNullOrEmpty($prev)) { $current[$resultsIdx] = $txt }
                    else { $current[$resultsIdx] = $prev + "`n" + $txt }
                }
                continue
            }
        }

        return [pscustomobject]@{
            HeaderIndex0 = $headerIdx0
            Headers      = $headers
            ColCount     = $expected
            Rows         = $rows
        }
    }
    finally {
        $p.Close()
        $p.Dispose()
    }
}

#endregion

#region ===================== Input Selection (Single Dialog) =====================

$initial = if ($DefaultFolder -and (Test-Path -LiteralPath $DefaultFolder -PathType Container)) {
    $DefaultFolder
} else {
    (Get-Location).Path
}

$sel = Select-CsvInputSingleDialog -InitialFolder $initial
$Folder = $sel.Folder
$csvFiles = @($sel.CsvFiles)

if ($EnableDebug) {
    Write-Host "Input folder: $Folder" -ForegroundColor Cyan
    Write-Host ("CSV files to process: {0}" -f $csvFiles.Count) -ForegroundColor Cyan
}

#endregion

#region ===================== SaveFileDialog =====================

$sfd = New-Object System.Windows.Forms.SaveFileDialog
$sfd.Title = "Save combined workbook as XLSX"
$sfd.Filter = "Excel Workbook (*.xlsx)|*.xlsx"
$sfd.InitialDirectory = $Folder
$sfd.FileName = "CombinedWorkbook.xlsx"
$sfd.OverwritePrompt = $false  # avoid double prompts; we handle overwrite ourselves

$savePath = if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $sfd.FileName) {
    $sfd.FileName
} else {
    Join-Path $Folder "CombinedWorkbook.xlsx"
}

if (-not $savePath.EndsWith(".xlsx", [System.StringComparison]::InvariantCultureIgnoreCase)) {
    $savePath += ".xlsx"
}

Ensure-OutputPathIsSafeOrExit -SavePath $savePath

#endregion

#region ===================== Excel COM Workflow =====================

$excel = $null
$wb = $null
$xlOpenXml = 51
$openAfterQuit = $false

try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $excel.EnableEvents = $false
    $excel.AskToUpdateLinks = $false

    $wb = $excel.Workbooks.Add()

    # CombinedData first worksheet
    $combinedSheet = Add-WorksheetAfterLast -Workbook $wb
    $combinedSheet.Name = "CombinedData"
    $combinedSheet.Move($wb.Sheets.Item(1))

    # reuse default Sheet* for first CSV sheet
    $firstCsvSheet = $null
    for ($i=1; $i -le $wb.Sheets.Count; $i++) {
        $s = $wb.Sheets.Item($i)
        if ([string]$s.Name -match '^Sheet\d+$') { $firstCsvSheet = $s; break }
    }
    if (-not $firstCsvSheet) { $firstCsvSheet = Add-WorksheetAfterLast -Workbook $wb }
    $usedFirstCsvSheet = $false

    # CombinedData setup
    $combinedInitialized = $false
    $combinedHeaders = $null
    $combinedColCount = 0
    $combinedRowOffset = 2
    $ipIdx = 0

    foreach ($csv in @($csvFiles)) {

        # 1) Full CSV -> its worksheet (preserve everything)
        $full = Parse-FullCsvPreserveAllLines -Path $csv.FullName
        $fullCols = [int]$full.MaxCols
        $fullRows = $full.Rows

        if ($EnableDebug) {
            Write-Host ("CSV Full Import: {0}  rows={1} maxCols={2}" -f $csv.Name, $fullRows.Count, $fullCols) -ForegroundColor Cyan
        }

        if ($fullCols -gt 0 -and $fullRows.Count -gt 0) {
            if (-not $usedFirstCsvSheet) {
                $ws = $firstCsvSheet
                $ws.Name = ConvertTo-SafeSheetName -Name $csv.BaseName -Workbook $wb
                $usedFirstCsvSheet = $true
            } else {
                $ws = Add-WorksheetAfterLast -Workbook $wb
                $ws.Name = ConvertTo-SafeSheetName -Name $csv.BaseName -Workbook $wb
            }

            $rowOffset = 1
            for ($p=0; $p -lt $fullRows.Count; $p += $WriteChunkSize) {
                $remaining = $fullRows.Count - $p
                $take = [Math]::Min($WriteChunkSize, $remaining)
                if ($take -le 0) { continue }

                $chunk = New-2DObjectArray -Rows $take -Cols $fullCols -Name "FullFileChunk"
                for ($r=0; $r -lt $take; $r++) {
                    $src = $fullRows[$p + $r]
                    for ($c=0; $c -lt $fullCols; $c++) { $chunk.SetValue($src[$c], $r, $c) }
                }

                Write-MatrixToExcel -Worksheet $ws -StartRow1 $rowOffset -StartCol1 1 -Matrix $chunk -Rows $take -Cols $fullCols -Context ("FullWrite {0} p={1} take={2}" -f $csv.Name,$p,$take)
                $rowOffset += $take
            }

            # CSV sheets: no formatting, default row height & no wrap
            Set-WorksheetDefaultRowHeightNoWrap -Worksheet $ws
        }

        # 2) Findings -> CombinedData
        $find = Parse-QualysFindingsSection -Path $csv.FullName

        if ($EnableDebug) {
            Write-Host ("  Findings: HeaderIndex0={0} Cols={1} Rows={2}" -f $find.HeaderIndex0, $find.ColCount, $find.Rows.Count) -ForegroundColor Gray
        }

        if (-not $combinedInitialized) {
            $combinedHeaders = $find.Headers
            $combinedColCount = [int]$find.ColCount
            $ipIdx = [Array]::IndexOf($combinedHeaders, 'IP')
            if ($ipIdx -lt 0) { $ipIdx = 0 }

            $hdr = New-2DObjectArray -Rows 1 -Cols $combinedColCount -Name "CombinedHeader"
            for ($c=0; $c -lt $combinedColCount; $c++) { $hdr.SetValue($combinedHeaders[$c], 0, $c) }

            Write-MatrixToExcel -Worksheet $combinedSheet -StartRow1 1 -StartCol1 1 -Matrix $hdr -Rows 1 -Cols $combinedColCount -Context "CombinedHeader"
            $combinedRowOffset = 2
            $combinedInitialized = $true
        }

        $pass = New-Object 'System.Collections.Generic.List[object[]]'
        foreach ($rowArr in $find.Rows) {
            if ($CombinedDataFilterMode -eq 'All') {
                $pass.Add($rowArr) | Out-Null
                continue
            }

            $ipVal = $rowArr[$ipIdx]
            $ipv4 = Get-IPv4FromText ([string]$ipVal)
            if ($ipv4) { $pass.Add($rowArr) | Out-Null; continue }

            if ($IncludeHostnameOnlyRows -and -not [string]::IsNullOrWhiteSpace([string]$ipVal)) {
                $pass.Add($rowArr) | Out-Null
            }
        }

        if ($EnableDebug) {
            Write-Host ("  CombinedData append: passRows={0} mode={1}" -f $pass.Count, $CombinedDataFilterMode) -ForegroundColor DarkGray
        }

        for ($p=0; $p -lt $pass.Count; $p += $WriteChunkSize) {
            $remaining = $pass.Count - $p
            $take = [Math]::Min($WriteChunkSize, $remaining)
            if ($take -le 0) { continue }

            $chunk = New-2DObjectArray -Rows $take -Cols $combinedColCount -Name "CombinedChunk"
            for ($r=0; $r -lt $take; $r++) {
                $src = $pass[$p + $r]
                for ($c=0; $c -lt $combinedColCount; $c++) { $chunk.SetValue($src[$c], $r, $c) }
            }

            Write-MatrixToExcel -Worksheet $combinedSheet -StartRow1 $combinedRowOffset -StartCol1 1 -Matrix $chunk -Rows $take -Cols $combinedColCount -Context ("CombinedWrite {0} p={1} take={2}" -f $csv.Name,$p,$take)
            $combinedRowOffset += $take
        }
    }

    Apply-CombinedDataPostProcessing -Worksheet $combinedSheet
    Remove-LeftoverDefaultSheets -Workbook $wb

    [void]$wb.SaveAs($savePath, $xlOpenXml)
    $wb.Saved = $true

    if (-not (Test-Path -LiteralPath $savePath)) {
        throw "Excel SaveAs failed — output file not created: $savePath"
    }

    Write-Host "Workbook saved to: $savePath" -ForegroundColor Green
    $openAfterQuit = $true
}
finally {
    # Always close the Excel instance created by this script
    try { if ($wb) { $wb.Close($false) } } catch {}
    try { if ($excel) { $excel.DisplayAlerts = $false; $excel.Quit() } } catch {}

    try { if ($wb) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) } } catch {}
    try { if ($excel) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } } catch {}

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}

if ($openAfterQuit -and (Test-Path -LiteralPath $savePath)) {
    Start-Process -FilePath $savePath | Out-Null
}

#endregion