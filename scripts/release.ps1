<#
.SYNOPSIS
    Build and publish a firmware GitHub Release from the local machine.
.DESCRIPTION
    Rebuilds the Keil project, prepares versioned hex/map/axf artifacts, creates
    or verifies the matching git tag, pushes the tag, and uploads artifacts to
    GitHub Release.
#>

param(
    [string]$Remote = "origin",
    [string]$OutputDir = "dist",
    [switch]$AllowDirty,
    [switch]$SkipBuild,
    [switch]$NoPush,
    [switch]$DryRun,
    [switch]$Draft,
    [switch]$Prerelease,
    [string]$Notes = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$ErrorMessage
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

function Get-DefineValue {
    param(
        [string]$Content,
        [string]$Name
    )

    $pattern = "(?m)^\s*#define\s+$([regex]::Escape($Name))\s+(\d+)\b"
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        throw "Could not find numeric define $Name in Core\Inc\main.h"
    }

    [int]$match.Groups[1].Value
}

function Get-FirmwareTag {
    $headerPath = Join-Path $RepoRoot "Core\Inc\main.h"
    $content = Get-Content $headerPath -Raw -Encoding UTF8
    $major = Get-DefineValue -Content $content -Name "VER_MAJOR"
    $minor = Get-DefineValue -Content $content -Name "VER_MINOR"
    $patch = Get-DefineValue -Content $content -Name "VER_PATCH"

    "v$major.$minor.$patch"
}

function Get-ReleaseNotes {
    param(
        [string]$Tag,
        [string]$OverrideNotes
    )

    if (-not [string]::IsNullOrWhiteSpace($OverrideNotes)) {
        return [PSCustomObject]@{
            Text = $OverrideNotes.Trim()
            Source = "-Notes parameter"
        }
    }

    $changelogPath = Join-Path $RepoRoot "CHANGELOG.md"
    if (-not (Test-Path $changelogPath)) {
        throw "CHANGELOG.md not found. Add a '## $Tag' section, or pass -Notes to override release notes."
    }

    $lines = @(Get-Content $changelogPath -Encoding UTF8)
    $headingPattern = "^\s*##\s+$([regex]::Escape($Tag))(\s|$)"
    $nextHeadingPattern = "^\s*##\s+"
    $startIndex = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $headingPattern) {
            $startIndex = $i
            break
        }
    }

    if ($startIndex -lt 0) {
        throw "CHANGELOG.md does not contain release notes for $Tag. Add a '## $Tag' section, or pass -Notes to override."
    }

    $noteLines = @()
    for ($i = $startIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $nextHeadingPattern) {
            break
        }
        $noteLines += $lines[$i]
    }

    while ($noteLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($noteLines[0])) {
        $noteLines = @($noteLines | Select-Object -Skip 1)
    }
    while ($noteLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($noteLines[$noteLines.Count - 1])) {
        $noteLines = @($noteLines | Select-Object -First ($noteLines.Count - 1))
    }

    $releaseNotes = ($noteLines -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($releaseNotes)) {
        throw "CHANGELOG.md section '## $Tag' is empty. Add release notes, or pass -Notes to override."
    }

    [PSCustomObject]@{
        Text = $releaseNotes
        Source = "CHANGELOG.md section ## $Tag"
    }
}

function Get-KeilProjectFile {
    $projectFiles = @(Get-ChildItem -Path (Join-Path $RepoRoot "MDK-ARM") -Filter "*.uvprojx" -File)
    if ($projectFiles.Count -ne 1) {
        throw "Expected exactly one .uvprojx under MDK-ARM, found $($projectFiles.Count)."
    }

    $projectFiles[0].FullName
}

function Prepare-ReleaseArtifacts {
    param(
        [string]$Tag,
        [string]$ArtifactDir
    )

    $projectFile = Get-KeilProjectFile
    [xml]$projectXml = Get-Content $projectFile -Encoding UTF8
    $targets = @($projectXml.Project.Targets.Target)
    if ($targets.Count -eq 0) {
        throw "No build targets found in: $projectFile"
    }

    $targetNode = $targets[0]
    $common = $targetNode.TargetOption.TargetCommonOption
    $projectDir = Split-Path $projectFile -Parent

    $outputDirName = $common.OutputDirectory
    if ([string]::IsNullOrWhiteSpace($outputDirName)) {
        $outputDirName = $targetNode.TargetName
    }
    $outputDirName = $outputDirName.Trim().TrimEnd('\', '/')
    $buildOutputDir = Join-Path $projectDir $outputDirName

    $outputName = $common.OutputName
    if ([string]::IsNullOrWhiteSpace($outputName)) {
        $outputName = $targetNode.TargetName
    }

    $requiredArtifacts = @(
        @{ Ext = "hex"; Path = Join-Path $buildOutputDir "$outputName.hex" },
        @{ Ext = "map"; Path = Join-Path $buildOutputDir "$outputName.map" },
        @{ Ext = "axf"; Path = Join-Path $buildOutputDir "$outputName.axf" }
    )

    $missing = @($requiredArtifacts | Where-Object { -not (Test-Path $_.Path) })
    if ($missing.Count -gt 0) {
        $missingList = ($missing | ForEach-Object { $_.Path }) -join ", "
        throw "Missing build artifacts: $missingList"
    }

    $artifactPath = Join-Path $RepoRoot $ArtifactDir
    $resolvedRepoRoot = (Resolve-Path $RepoRoot).Path.TrimEnd('\')
    New-Item -Path $artifactPath -ItemType Directory -Force | Out-Null
    $resolvedArtifactPath = (Resolve-Path $artifactPath).Path.TrimEnd('\')
    if (-not $resolvedArtifactPath.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to prepare artifacts outside repo root: $resolvedArtifactPath"
    }

    Get-ChildItem -Path $resolvedArtifactPath -File | Remove-Item -Force

    $copied = @()
    foreach ($artifact in $requiredArtifacts) {
        $destination = Join-Path $resolvedArtifactPath "$($outputName)_$Tag.$($artifact.Ext)"
        Copy-Item -Path $artifact.Path -Destination $destination -Force
        $copied += Get-Item $destination
    }

    Write-Host "Keil target: $($targetNode.TargetName)"
    Write-Host "Build output: $buildOutputDir"
    Write-Host "Release artifacts:"
    foreach ($file in $copied) {
        Write-Host "  $($file.FullName)"
    }

    $copied
}

function Get-GitHubRepository {
    param([string]$RemoteName)

    $remoteOutput = & git remote get-url $RemoteName
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteOutput)) {
        throw "Could not read git remote '$RemoteName'. Add a GitHub remote first, for example: git remote add origin https://github.com/<owner>/<repo>.git"
    }
    $url = $remoteOutput.Trim()

    if ($url -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    throw "Remote '$RemoteName' is not a GitHub URL: $url"
}

function Test-Command {
    param([string]$Name)

    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-GhCommand {
    $command = Get-Command "gh" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidatePaths = @(
        (Join-Path $env:ProgramFiles "GitHub CLI\gh.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "GitHub CLI\gh.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI\gh.exe")
    )

    foreach ($candidatePath in $candidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path $candidatePath)) {
            return $candidatePath
        }
    }

    ""
}

function Get-Uv4Path {
    if (-not [string]::IsNullOrWhiteSpace($env:KEIL_UV4)) {
        return $env:KEIL_UV4
    }

    "d:\MDK_ARM\Keil_v5\UV4\UV4.exe"
}

function Get-GitHubApiHeaders {
    @{
        Authorization = "Bearer $env:GITHUB_TOKEN"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Get-RemoteTagCommit {
    param(
        [string]$RemoteName,
        [string]$Tag,
        [string]$Repository = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and -not [string]::IsNullOrWhiteSpace($Repository)) {
        $headers = Get-GitHubApiHeaders
        $apiBase = "https://api.github.com/repos/$Repository"

        try {
            $ref = Invoke-RestMethod -Method "Get" -Uri "$apiBase/git/ref/tags/$Tag" -Headers $headers
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                return ""
            }
            throw "Could not query remote tag '$Tag' from GitHub API. Check GITHUB_TOKEN permissions and network access."
        }

        if ($ref.object.type -eq "commit") {
            return $ref.object.sha
        }

        if ($ref.object.type -eq "tag") {
            $tagObject = Invoke-RestMethod -Method "Get" -Uri $ref.object.url -Headers $headers
            return $tagObject.object.sha
        }

        throw "Remote tag '$Tag' points to unsupported object type: $($ref.object.type)"
    }

    $output = & git ls-remote --tags $RemoteName "refs/tags/$Tag" "refs/tags/$Tag^{}"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not query remote tag '$Tag' from '$RemoteName'. Check git remote access with: git ls-remote $RemoteName. If git remote access is unstable, set GITHUB_TOKEN so the release script can use the GitHub API for preflight checks."
    }

    $lines = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        return ""
    }

    $peeled = $lines | Where-Object { $_ -match "refs/tags/$([regex]::Escape($Tag))\^\{\}$" } | Select-Object -First 1
    if ($peeled) {
        return ($peeled -split "\s+")[0]
    }

    ($lines[0] -split "\s+")[0]
}

function Test-HeadExistsOnRemote {
    param(
        [string]$RemoteName,
        [string]$HeadCommit,
        [string]$Repository = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN) -and -not [string]::IsNullOrWhiteSpace($Repository)) {
        $headers = Get-GitHubApiHeaders
        $apiBase = "https://api.github.com/repos/$Repository"

        try {
            Invoke-RestMethod -Method "Get" -Uri "$apiBase/commits/$HeadCommit" -Headers $headers | Out-Null
            return $true
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 404) {
                return $false
            }
            throw "Could not query commit '$HeadCommit' from GitHub API. Check GITHUB_TOKEN permissions and network access."
        }
    }

    $output = & git ls-remote $RemoteName
    if ($LASTEXITCODE -ne 0) {
        $remoteUrl = (& git remote get-url $RemoteName 2>$null)
        if ($remoteUrl -match "^git@github\.com:") {
            throw "Could not query remote refs from '$RemoteName'. The remote uses SSH ($remoteUrl); verify SSH/network access with: ssh -T git@github.com. If SSH/git remote access is unstable, set GITHUB_TOKEN so the release script can use the GitHub API for preflight checks."
        }

        throw "Could not query remote refs from '$RemoteName'. Verify access with: git ls-remote $RemoteName. If git remote access is unstable, set GITHUB_TOKEN so the release script can use the GitHub API for preflight checks."
    }

    @($output | Where-Object { $_ -match "^$HeadCommit\s+" }).Count -gt 0
}

function Invoke-Preflight {
    param(
        [string]$Tag,
        [string]$RemoteName,
        [bool]$IsDryRun,
        [bool]$AllowDirtyTree,
        [bool]$BuildSkipped
    )

    Write-Host "Preflight checks..."

    if (-not (Test-Command "git")) {
        throw "git command not found."
    }

    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Current directory is not inside a git repository."
    }

    $headCommit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($headCommit)) {
        throw "Could not resolve HEAD commit."
    }

    $buildScript = Join-Path $RepoRoot "build.ps1"
    if (-not (Test-Path $buildScript)) {
        throw "Build script not found: $buildScript"
    }

    $projectFile = Get-KeilProjectFile
    if (-not (Test-Path $projectFile)) {
        throw "Keil project file not found: $projectFile"
    }

    $headerPath = Join-Path $RepoRoot "Core\Inc\main.h"
    if (-not (Test-Path $headerPath)) {
        throw "Version header not found: $headerPath"
    }

    if (-not $BuildSkipped) {
        $uv4 = Get-Uv4Path
        if (-not (Test-Path $uv4)) {
            throw "Keil UV4.exe not found: $uv4. Set KEIL_UV4 if Keil is installed elsewhere."
        }
    }

    if (-not $AllowDirtyTree) {
        $dirty = (& git status --porcelain)
        if ($dirty) {
            throw "Working tree is not clean. Commit changes first, or rerun with -AllowDirty."
        }
    }

    & git rev-parse -q --verify "refs/tags/$Tag" *> $null
    if ($LASTEXITCODE -eq 0) {
        $tagCommit = (& git rev-list -n 1 $Tag).Trim()
        if ($tagCommit -ne $headCommit) {
            throw "Local tag $Tag already exists but does not point to HEAD."
        }
    }

    if ($IsDryRun) {
        Write-Host "Preflight OK"
        return
    }

    $repository = Get-GitHubRepository -RemoteName $RemoteName
    $ghPath = Resolve-GhCommand

    if ([string]::IsNullOrWhiteSpace($ghPath) -and [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        throw "GitHub auth not found. Install/login GitHub CLI (`gh auth login`) or set GITHUB_TOKEN."
    }

    if (-not [string]::IsNullOrWhiteSpace($ghPath)) {
        $authStatusOutput = & $ghPath auth status 2>&1
        if ($LASTEXITCODE -ne 0 -and [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $authStatusText = ($authStatusOutput | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            throw "GitHub CLI auth check failed. Run '$ghPath auth status' for details, or set GITHUB_TOKEN. Output: $authStatusText"
        }
    }

    $remoteTagCommit = Get-RemoteTagCommit -RemoteName $RemoteName -Tag $Tag -Repository $repository
    if (-not [string]::IsNullOrWhiteSpace($remoteTagCommit) -and $remoteTagCommit -ne $headCommit) {
        throw "Remote tag $Tag already exists but does not point to HEAD."
    }

    if (-not (Test-HeadExistsOnRemote -RemoteName $RemoteName -HeadCommit $headCommit -Repository $repository)) {
        Write-Warning "HEAD commit was not found on remote refs. The tag push can still upload it, but the branch may not be pushed."
    }

    Write-Host "Preflight OK"
    $repository
}

function Publish-WithGh {
    param(
        [string]$GhPath,
        [string]$Tag,
        [string[]]$Files,
        [string]$ReleaseNotes,
        [bool]$IsDraft,
        [bool]$IsPrerelease
    )

    & $GhPath release view $Tag *> $null
    $releaseExists = ($LASTEXITCODE -eq 0)

    if ($releaseExists) {
        Write-Host "Updating GitHub Release $Tag"
        Invoke-Checked -FilePath $GhPath -Arguments @("release", "edit", $Tag, "--notes", $ReleaseNotes) -ErrorMessage "Failed to update release notes with gh."
        $args = @("release", "upload", $Tag) + $Files + @("--clobber")
        Invoke-Checked -FilePath $GhPath -Arguments $args -ErrorMessage "Failed to upload release assets with gh."
        return
    }

    Write-Host "Creating GitHub Release $Tag"
    $args = @("release", "create", $Tag) + $Files + @("--title", $Tag)
    $args += @("--notes", $ReleaseNotes)
    if ($IsDraft) { $args += "--draft" }
    if ($IsPrerelease) { $args += "--prerelease" }

    Invoke-Checked -FilePath $GhPath -Arguments $args -ErrorMessage "Failed to create GitHub Release with gh."
}

function Invoke-GitHubApi {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body = "",
        [string]$ContentType = "application/json",
        [string]$InFile = ""
    )

    if ([string]::IsNullOrWhiteSpace($InFile)) {
        if ([string]::IsNullOrWhiteSpace($Body)) {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
        } else {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType $ContentType -Body $Body
        }
    } else {
        Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -ContentType $ContentType -InFile $InFile
    }
}

function Publish-WithApi {
    param(
        [string]$Repository,
        [string]$Tag,
        [System.IO.FileInfo[]]$Files,
        [string]$ReleaseNotes,
        [bool]$IsDraft,
        [bool]$IsPrerelease
    )

    if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        throw "GitHub auth not found. Install/login GitHub CLI (`gh auth login`) or set GITHUB_TOKEN."
    }

    $headers = @{
        Authorization = "Bearer $env:GITHUB_TOKEN"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $apiBase = "https://api.github.com/repos/$Repository"

    try {
        $release = Invoke-GitHubApi -Method "Get" -Uri "$apiBase/releases/tags/$Tag" -Headers $headers
        Write-Host "Updating GitHub Release $Tag"
        $body = @{
            body = $ReleaseNotes
        } | ConvertTo-Json
        $release = Invoke-GitHubApi -Method "Patch" -Uri "$apiBase/releases/$($release.id)" -Headers $headers -ContentType "application/json" -Body $body
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            throw
        }

        Write-Host "Creating GitHub Release $Tag"
        $body = @{
            tag_name = $Tag
            name = $Tag
            body = $ReleaseNotes
            draft = $IsDraft
            prerelease = $IsPrerelease
        } | ConvertTo-Json

        $release = Invoke-GitHubApi -Method "Post" -Uri "$apiBase/releases" -Headers $headers -ContentType "application/json" -Body $body
    }

    $existingAssets = @(Invoke-GitHubApi -Method "Get" -Uri $release.assets_url -Headers $headers)
    $uploadBase = $release.upload_url -replace "\{\?name,label\}$", ""

    foreach ($file in $Files) {
        $oldAsset = $existingAssets | Where-Object { $_.name -eq $file.Name } | Select-Object -First 1
        if ($oldAsset) {
            Invoke-GitHubApi -Method "Delete" -Uri "$apiBase/releases/assets/$($oldAsset.id)" -Headers $headers | Out-Null
            Write-Host "Deleted old asset: $($file.Name)"
        }

        $encodedName = [System.Uri]::EscapeDataString($file.Name)
        Invoke-GitHubApi `
            -Method "Post" `
            -Uri "$uploadBase?name=$encodedName" `
            -Headers $headers `
            -ContentType "application/octet-stream" `
            -InFile $file.FullName | Out-Null
        Write-Host "Uploaded asset: $($file.Name)"
    }
}

$tag = Get-FirmwareTag
$releaseNotes = Get-ReleaseNotes -Tag $tag -OverrideNotes $Notes
$repository = Invoke-Preflight `
    -Tag $tag `
    -RemoteName $Remote `
    -IsDryRun ([bool]$DryRun) `
    -AllowDirtyTree ([bool]$AllowDirty) `
    -BuildSkipped ([bool]$SkipBuild)

Write-Host "Release tag: $tag"
if ($DryRun) {
    Write-Host "Repository:  skipped in dry run"
} else {
    Write-Host "Repository:  $repository"
}
Write-Host "Release notes: $($releaseNotes.Source)"

if (-not $SkipBuild) {
    & (Join-Path $RepoRoot "build.ps1") -Rebuild
    if ($LASTEXITCODE -ne 0) {
        throw "Keil build failed."
    }
}

$files = @(Prepare-ReleaseArtifacts -Tag $tag -ArtifactDir $OutputDir)
if ($files.Count -ne 3) {
    throw "Expected 3 release artifacts, found $($files.Count)."
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run complete. No tag was created, pushed, or uploaded."
    exit 0
}

& git rev-parse -q --verify "refs/tags/$tag" *> $null
$tagExists = ($LASTEXITCODE -eq 0)
if ($tagExists) {
    Write-Host "Tag already exists locally: $tag"
} else {
    Invoke-Checked -FilePath "git" -Arguments @("tag", $tag) -ErrorMessage "Failed to create git tag $tag."
    Write-Host "Created local tag: $tag"
}

if (-not $NoPush) {
    Invoke-Checked -FilePath "git" -Arguments @("push", $Remote, $tag) -ErrorMessage "Failed to push git tag $tag."
}

$ghPath = Resolve-GhCommand
if (-not [string]::IsNullOrWhiteSpace($ghPath)) {
    Publish-WithGh -GhPath $ghPath -Tag $tag -Files @($files.FullName) -ReleaseNotes $releaseNotes.Text -IsDraft ([bool]$Draft) -IsPrerelease ([bool]$Prerelease)
} else {
    Publish-WithApi -Repository $repository -Tag $tag -Files $files -ReleaseNotes $releaseNotes.Text -IsDraft ([bool]$Draft) -IsPrerelease ([bool]$Prerelease)
}

Write-Host ""
Write-Host "Release complete: $tag"
