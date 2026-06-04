<#
.SYNOPSIS
    Keil MDK Build Script
.DESCRIPTION
    Incremental/rebuild for the current Keil project with progress bar,
    build time, error reporting, and firmware size display. Project settings
    are read from the .uvprojx file under MDK-ARM.
.EXAMPLE
    .\build.ps1                          # Incremental build
    .\build.ps1 -Rebuild                 # Full rebuild
    .\build.ps1 -Clean                   # Clean
#>

param(
    [string]$Target = "",
    [switch]$Rebuild,
    [switch]$Clean
)

# ============================================================================
# Configuration
# ============================================================================
$UV4 = "d:\MDK_ARM\Keil_v5\UV4\UV4.exe"
if (-not [string]::IsNullOrWhiteSpace($env:KEIL_UV4)) {
    $UV4 = $env:KEIL_UV4
}
$ProjectDir = Join-Path $PSScriptRoot "MDK-ARM"

function Resolve-UvprojFile {
    param([string]$Directory)

    $projectFiles = @(Get-ChildItem -Path $Directory -Filter "*.uvprojx" -File -ErrorAction SilentlyContinue)
    if ($projectFiles.Count -eq 0) {
        Write-Host "[ERROR] No .uvprojx file found under: $Directory" -ForegroundColor Red
        exit 1
    }
    if ($projectFiles.Count -gt 1) {
        $available = ($projectFiles | ForEach-Object { $_.Name }) -join ", "
        Write-Host "[ERROR] Multiple .uvprojx files found under: $Directory" -ForegroundColor Red
        Write-Host "        Please keep one Keil project file or update this script. Available: $available"
        exit 1
    }

    $projectFiles[0].FullName
}

$ProjectFile = Resolve-UvprojFile -Directory $ProjectDir

function Get-UvprojConfig {
    param(
        [string]$ProjectPath,
        [string]$RequestedTarget
    )

    if (-not (Test-Path $ProjectPath)) {
        Write-Host "[ERROR] Project file not found: $ProjectPath" -ForegroundColor Red
        exit 1
    }

    [xml]$projectXml = Get-Content $ProjectPath -Encoding UTF8
    $targets = @($projectXml.Project.Targets.Target)
    if ($targets.Count -eq 0) {
        Write-Host "[ERROR] No build targets found in: $ProjectPath" -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($RequestedTarget)) {
        $targetNode = $targets[0]
    } else {
        $targetNode = $targets | Where-Object { $_.TargetName -eq $RequestedTarget } | Select-Object -First 1
        if (-not $targetNode) {
            $available = ($targets | ForEach-Object { $_.TargetName }) -join ", "
            Write-Host "[ERROR] Target '$RequestedTarget' not found. Available: $available" -ForegroundColor Red
            exit 1
        }
    }

    $common = $targetNode.TargetOption.TargetCommonOption
    $outputDirName = $common.OutputDirectory
    if ([string]::IsNullOrWhiteSpace($outputDirName)) {
        $outputDirName = $targetNode.TargetName
    }

    $outputDirName = $outputDirName.Trim().TrimEnd('\', '/')
    $outputDir = Join-Path $ProjectDir $outputDirName
    $outputName = $common.OutputName
    if ([string]::IsNullOrWhiteSpace($outputName)) {
        $outputName = $targetNode.TargetName
    }

    $sourceFileCount = @($targetNode.Groups.Group.Files.File | Where-Object {
        $_.FileType -in @("1", "2")
    }).Count

    @{
        Project    = $ProjectPath
        Target     = $targetNode.TargetName
        HexFile    = Join-Path $outputDir "$outputName.hex"
        MapFile    = Join-Path $outputDir "$outputName.map"
        LogFile    = Join-Path $outputDir "$outputName.build_log.htm"
        Name       = $targetNode.TargetName
        ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
        TotalFiles = $sourceFileCount
    }
}

$cfg = Get-UvprojConfig -ProjectPath $ProjectFile -RequestedTarget $Target

# ============================================================================
# Verify UV4 exists
# ============================================================================
if (-not (Test-Path $UV4)) {
    Write-Host "[ERROR] Keil UV4 not found: $UV4" -ForegroundColor Red
    Write-Host "Please update the `$UV4 path in this script."
    exit 1
}

# ============================================================================
# Determine build mode
# ============================================================================
if ($Clean) {
    $UV4Flag = "-c"
    $ModeName = "Clean"
} elseif ($Rebuild) {
    $UV4Flag = "-r"
    $ModeName = "Rebuild"
} else {
    $UV4Flag = "-b"
    $ModeName = "Build"
}

# ============================================================================
# Print header
# ============================================================================
function Write-Header {
    $line = "=" * 60
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $($cfg.ProjectName) - $ModeName $($cfg.Name)" -ForegroundColor White
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  Project: $($cfg.Project)"
    Write-Host "  Target:  $($cfg.Target)"
    Write-Host "  Time:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

Write-Header

# ============================================================================
# Progress bar function
# ============================================================================
function Show-BuildProgress {
    param([int]$Compiled, [int]$Total, [string]$CurrentFile)

    if ($Total -le 0) { $Total = 1 }
    $pct = [math]::Min(100, [math]::Floor($Compiled * 100 / $Total))
    $barWidth = 40
    $filled = [math]::Floor($pct * $barWidth / 100)
    $empty = $barWidth - $filled

    $bar = ("#" * $filled) + ("-" * $empty)
    $status = "[$bar] $pct% ($Compiled/$Total)"

    if ($CurrentFile) {
        $displayFile = $CurrentFile
        if ($displayFile.Length -gt 30) {
            $displayFile = "..." + $displayFile.Substring($displayFile.Length - 27)
        }
        $status += " $displayFile"
    }

    $padded = $status.PadRight(90)
    Write-Host "`r$padded" -NoNewline -ForegroundColor Yellow
}

# ============================================================================
# Run build with progress monitoring
# ============================================================================
$startTime = Get-Date

# Delete old log to track progress from scratch
if (Test-Path $cfg.LogFile) {
    Remove-Item $cfg.LogFile -Force 2>$null
}

# Start UV4 and monitor the build log
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $UV4
$psi.Arguments = "$UV4Flag `"$($cfg.Project)`" -t `"$($cfg.Target)`" -j0 -o `"$($cfg.LogFile)`""
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::Start($psi)

# Monitor progress by watching the log file
$lastCount = 0
$lastFile = ""
if ($Clean) {
    Write-Host "  Cleaning..." -ForegroundColor Gray
} else {
    Write-Host "  Compiling..." -ForegroundColor Gray
}

while (-not $process.HasExited) {
    if (Test-Path $cfg.LogFile) {
        try {
            # Read log file content to count compiled files
            $logContent = [System.IO.File]::ReadAllText($cfg.LogFile, [System.Text.Encoding]::UTF8)
            $matches_found = [regex]::Matches($logContent, "compiling\s+(\S+)")
            $compiled = $matches_found.Count

            if ($compiled -gt $lastCount) {
                $lastCount = $compiled
                if ($matches_found.Count -gt 0) {
                    $lastFile = $matches_found[$matches_found.Count - 1].Groups[1].Value
                }
                Show-BuildProgress -Compiled $compiled -Total $cfg.TotalFiles -CurrentFile $lastFile
            }
        } catch {
            # File might be locked by UV4, skip this iteration
        }
    }
    Start-Sleep -Milliseconds 500
}

$exitCode = $process.ExitCode
$endTime = Get-Date
$elapsed = $endTime - $startTime

# Show 100% or final state
if ((-not $Clean) -and $exitCode -le 1) {
    Show-BuildProgress -Compiled $cfg.TotalFiles -Total $cfg.TotalFiles -CurrentFile "Done"
}
Write-Host ""
Write-Host ""

# ============================================================================
# Parse build results
# ============================================================================
$errors = @()
$warningCount = 0
$errorCount = 0
$logLines = @()
$summaryFound = $false

if (Test-Path $cfg.LogFile) {
    $logLines = Get-Content $cfg.LogFile -Encoding UTF8 -ErrorAction SilentlyContinue

    foreach ($line in $logLines) {
        if ($line -match "(\d+)\s+Error\(s\),\s+(\d+)\s+Warning\(s\)") {
            $errorCount = [int]$Matches[1]
            $warningCount = [int]$Matches[2]
            $summaryFound = $true
        }
        if ($line -match ":\s+error") {
            $errors += $line.Trim()
            if (-not $summaryFound) { $errorCount++ }
        }
        if ((-not $summaryFound) -and ($line -match ":\s+warning")) {
            $warningCount++
        }
    }
}

# ============================================================================
# Firmware size
# ============================================================================
$hexSizeKB = "N/A"
if ((-not $Clean) -and (Test-Path $cfg.HexFile)) {
    $fileInfo = Get-Item $cfg.HexFile
    $hexSizeKB = "{0:N1} KB" -f ($fileInfo.Length / 1024)
}

$codeSize = ""
$roSize = ""
$rwSize = ""
$ziSize = ""
$romTotal = ""

if (-not $Clean) {
    foreach ($line in $logLines) {
        if ($line -match "Program Size:\s+Code=(\d+)\s+RO-data=(\d+)\s+RW-data=(\d+)\s+ZI-data=(\d+)") {
            $codeSize = $Matches[1]
            $roSize = $Matches[2]
            $rwSize = $Matches[3]
            $ziSize = $Matches[4]
        }
    }

    if (Test-Path $cfg.MapFile) {
        $mapContent = Get-Content $cfg.MapFile -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $mapContent) {
            if ((-not $codeSize) -and $line -match "^\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)") {
                $codeSize = $Matches[1]
                $roSize = $Matches[3]
                $rwSize = $Matches[4]
                $ziSize = $Matches[5]
            }
            if ($line -match "Total ROM Size.*?(\d+)") {
                $romTotal = $Matches[1]
            }
        }
    }
}

# ============================================================================
# Print results
# ============================================================================
$line = "=" * 60
$elapsedStr = "{0}m {1}s" -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

Write-Host $line -ForegroundColor Cyan
$diagnostics = "$errorCount errors, $warningCount warnings"
if ($exitCode -eq 0) {
    Write-Host "  BUILD OK  ($elapsedStr, $diagnostics)" -ForegroundColor Green
} elseif ($exitCode -eq 1) {
    Write-Host "  BUILD OK  ($elapsedStr, $diagnostics)" -ForegroundColor Yellow
} else {
    Write-Host "  BUILD FAILED  ($elapsedStr, $diagnostics)" -ForegroundColor Red
}
Write-Host $line -ForegroundColor Cyan

# Firmware size (one-line summary + ROM total)
if ($codeSize) {
    Write-Host "  Code=$codeSize  RO=$roSize  RW=$rwSize  ZI=$ziSize" -ForegroundColor Gray
}
if ($romTotal) {
    $romKB = "{0:N1} KB" -f ([int]$romTotal / 1024)
    Write-Host "  ROM: $romTotal bytes ($romKB)  HEX: $hexSizeKB" -ForegroundColor White
} elseif ($hexSizeKB -ne "N/A") {
    Write-Host "  HEX: $hexSizeKB" -ForegroundColor White
}

# Errors detail
if ($errors.Count -gt 0) {
    Write-Host ""
    foreach ($err in $errors) {
        Write-Host "  $err" -ForegroundColor Red
    }
}

Write-Host ""

exit $exitCode
