#Requires -Version 5.1
<#
.SYNOPSIS
    Archives one or more folders into a ZIP file and uploads it to a MEGA.nz folder.

.DESCRIPTION
    Uses the built-in Compress-Archive cmdlet to zip folders, then uploads the
    archive to MEGA.nz using MEGAcmd (mega-put). MEGAcmd must be installed and
    the user must be logged in before running this script.

    MEGAcmd download: https://mega.nz/cmd

.PARAMETER FoldersToArchive
    One or more local folder paths to include in the ZIP archive.

.PARAMETER DestinationZip
    Full path for the resulting ZIP file (e.g. "C:\Backups\archive.zip").
    If not provided, a timestamped file is created in the system TEMP folder.

.PARAMETER MegaDestinationFolder
    The remote MEGA.nz path where the ZIP should be uploaded (e.g. "/Backups/Daily").

.PARAMETER MegaEmail
    (Optional) Your MEGA.nz email. If provided the script will log in before uploading.

.PARAMETER MegaPassword
    (Optional) Your MEGA.nz password. Used only when MegaEmail is also provided.
    Consider using a secure credential store instead of plain text.

.PARAMETER DeleteZipAfterUpload
    Switch. If set, the local ZIP file is deleted after a successful upload.

.PARAMETER MaxBackups
    (Optional) Maximum number of ZIP backups to keep in the MEGA destination folder.
    After a successful upload, if the total number of ZIPs exceeds this value the
    oldest ones (sorted by filename, which contains a timestamp) are deleted automatically.
    Set to 0 to disable pruning (default).

.EXAMPLE
    # Archive two folders and upload to /Backups/Daily on MEGA
    .\Backup-ToMega.ps1 `
        -FoldersToArchive "C:\Projects\WebApp", "C:\Projects\Database" `
        -DestinationZip   "C:\Temp\backup_2024.zip" `
        -MegaDestinationFolder "/Backups/Daily" `
        -DeleteZipAfterUpload

.EXAMPLE
    # Three folders, auto-named ZIP, stay logged in via MEGAcmd session
    .\Backup-ToMega.ps1 `
        -FoldersToArchive "C:\Docs", "C:\Photos", "C:\Music" `
        -MegaDestinationFolder "/Archive/Media"

.EXAMPLE
    # Keep only the 3 most recent backups in the MEGA folder
    .\Backup-ToMega.ps1 `
        -FoldersToArchive "C:\Data" `
        -MegaDestinationFolder "/Backups/Daily" `
        -MaxBackups 3 `
        -DeleteZipAfterUpload
#>

[CmdletBinding()]
param (
    # ── REQUIRED ──────────────────────────────────────────────────────────────
    [Parameter(Mandatory = $true, HelpMessage = "One or more folder paths to archive.")]
    [ValidateNotNullOrEmpty()]
    [string[]] $FoldersToArchive,

    [Parameter(Mandatory = $true, HelpMessage = "Remote MEGA path, e.g. /Backups/Daily")]
    [ValidateNotNullOrEmpty()]
    [string] $MegaDestinationFolder,

    # ── OPTIONAL ──────────────────────────────────────────────────────────────
    [Parameter(HelpMessage = "Full path for the output ZIP. Auto-generated if omitted.")]
    [string] $DestinationZip = "",

    [Parameter(HelpMessage = "MEGA email for login. Skip if already logged in via MEGAcmd.")]
    [string] $MegaEmail = "",

    [Parameter(HelpMessage = "MEGA password. Only used when MegaEmail is provided.")]
    [string] $MegaPassword = "",

    [Parameter(HelpMessage = "Delete the local ZIP after a successful upload.")]
    [switch] $DeleteZipAfterUpload,

    [Parameter(HelpMessage = "Max number of ZIP backups to keep in the MEGA folder. 0 = unlimited.")]
    [ValidateRange(0, 9999)]
    [int] $MaxBackups = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Helper: Write-Step ────────────────────────────────────────────────────────
function Write-Step {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

# ── Helper: Assert MEGAcmd is available ───────────────────────────────────────
function Assert-MegaCmd {
    $cmd = Get-Command "mega-put" -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw @"
MEGAcmd not found on PATH.
Please install it from https://mega.nz/cmd and ensure the install directory
is in your PATH environment variable, then restart PowerShell.
"@
    }
    Write-Step "MEGAcmd found at: $($cmd.Source)" "Green"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 – Validate source folders
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Validating source folders..."

foreach ($folder in $FoldersToArchive) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        throw "Source folder not found or is not a directory: '$folder'"
    }
}
Write-Host "  All $($FoldersToArchive.Count) folder(s) verified." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 – Resolve destination ZIP path
# ─────────────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($DestinationZip)) {
    $timestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
    $DestinationZip = Join-Path $env:TEMP "mega_backup_$timestamp.zip"
}

# Ensure parent directory exists
$zipParent = Split-Path $DestinationZip -Parent
if ($zipParent -and -not (Test-Path $zipParent)) {
    New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
}

Write-Step "Output ZIP: $DestinationZip"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 – Create the ZIP archive
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Creating ZIP archive..."

# Remove existing ZIP to avoid Compress-Archive 'already exists' error
if (Test-Path -LiteralPath $DestinationZip) {
    Remove-Item -LiteralPath $DestinationZip -Force
}

# Compress-Archive supports multiple source paths natively
try {
    Compress-Archive -Path $FoldersToArchive -DestinationPath $DestinationZip -CompressionLevel Optimal
} catch {
    throw "Failed to create ZIP archive: $_"
}

$zipSize = (Get-Item $DestinationZip).Length / 1MB
Write-Host "  Archive created successfully. Size: $([math]::Round($zipSize, 2)) MB" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 – Check MEGAcmd
# ─────────────────────────────────────────────────────────────────────────────
Assert-MegaCmd

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 – (Optional) Log in to MEGA
# ─────────────────────────────────────────────────────────────────────────────
if (-not [string]::IsNullOrWhiteSpace($MegaEmail)) {
    Write-Step "Logging in to MEGA as $MegaEmail..."
    $loginOutput = & mega-login $MegaEmail $MegaPassword 2>&1
    Write-Host "  $loginOutput"
    if ($LASTEXITCODE -ne 0) {
        throw "MEGA login failed (exit code $LASTEXITCODE). Output: $loginOutput"
    }
    Write-Host "  Login successful." -ForegroundColor Green
} else {
    Write-Step "Skipping login – using existing MEGAcmd session." "Yellow"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 – Ensure remote folder exists
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Ensuring remote folder exists: $MegaDestinationFolder"
$mkdirOutput = & mega-mkdir -p $MegaDestinationFolder 2>&1
# mega-mkdir returns non-zero if folder already exists on some versions; ignore that
Write-Host "  $mkdirOutput" -ForegroundColor DarkGray

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7 – Upload to MEGA
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Uploading '$DestinationZip' to MEGA path '$MegaDestinationFolder'..."

$uploadOutput = & mega-put $DestinationZip $MegaDestinationFolder 2>&1
Write-Host $uploadOutput

if ($LASTEXITCODE -ne 0) {
    throw "Upload failed (exit code $LASTEXITCODE). Output: $uploadOutput"
}
Write-Host "  Upload completed successfully." -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8 – (Optional) Prune old backups on MEGA
# ─────────────────────────────────────────────────────────────────────────────
if ($MaxBackups -gt 0) {
    Write-Step "Checking backup retention (max: $MaxBackups) in '$MegaDestinationFolder'..."

    # mega-ls -l prints one entry per line in the format:
    #   <perms>  <owner>  <size>  <date> <time>  <name>
    # We only care about .zip files and sort them by name (which contains the timestamp).
    $lsOutput = & mega-ls -l $MegaDestinationFolder 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: Could not list remote folder (exit $LASTEXITCODE). Skipping pruning." -ForegroundColor Yellow
    } else {
        # Parse filenames from the ls output – last whitespace-separated token on each line
        $remoteZips = $lsOutput |
            Where-Object { $_ -match '\.zip\s*$' } |
            ForEach-Object { ($_ -split '\s+')[-1] } |
            Sort-Object   # lexicographic sort == chronological because names are timestamped

        $totalZips = $remoteZips.Count
        Write-Host "  Found $totalZips ZIP file(s) in remote folder." -ForegroundColor Gray

        if ($totalZips -gt $MaxBackups) {
            $deleteCount = $totalZips - $MaxBackups
            $toDelete    = $remoteZips | Select-Object -First $deleteCount

            foreach ($oldFile in $toDelete) {
                $remotePath = "$MegaDestinationFolder/$oldFile"
                Write-Host "  Deleting old backup: $remotePath" -ForegroundColor Yellow
                $rmOutput = & mega-rm $remotePath 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "  WARNING: Failed to delete '$remotePath' (exit $LASTEXITCODE): $rmOutput" -ForegroundColor Yellow
                } else {
                    Write-Host "  Deleted: $remotePath" -ForegroundColor DarkYellow
                }
            }
            Write-Host "  Pruning complete. Removed $deleteCount old backup(s)." -ForegroundColor Green
        } else {
            Write-Host "  No pruning needed ($totalZips / $MaxBackups slots used)." -ForegroundColor Green
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9 – (Optional) Delete local ZIP
# ─────────────────────────────────────────────────────────────────────────────
if ($DeleteZipAfterUpload) {
    Write-Step "Deleting local ZIP..."
    Remove-Item -LiteralPath $DestinationZip -Force
    Write-Host "  Deleted: $DestinationZip" -ForegroundColor Yellow
}

Write-Step "All done!" "Green"
