#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet("Release")]
    [string] $Configuration = "Release",

    [ValidateSet("win-x64")]
    [string] $Runtime = "win-x64",

    [switch] $SkipTests,
    [switch] $SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)] [string] $Command,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command $($Arguments -join ' ')"
    }
}

function Write-Sha256File {
    param([Parameter(Mandatory)] [string] $Path)

    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText(
        "$($item.FullName).sha256",
        "$hash *$($item.Name)`n",
        [System.Text.Encoding]::ASCII
    )
}

function Find-InnoCompiler {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw "Inno Setup 6 or newer was not found. Install it or use -SkipInstaller."
}

$scriptDirectory = Split-Path -Parent $PSCommandPath
$repositoryRoot = (Resolve-Path (Join-Path $scriptDirectory "..")).Path
$windowsRoot = Join-Path $repositoryRoot "app\ClassScribe.Windows"
$solutionPath = Join-Path $windowsRoot "ClassScribe.Windows.slnx"
$applicationProject = Join-Path $windowsRoot "src\ClassScribe.Windows\ClassScribe.Windows.csproj"
$installerScript = Join-Path $windowsRoot "installer\ClassScribe.iss"
$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot "VERSION") -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION must use X.Y.Z format; got '$version'."
}

$buildRoot = Join-Path $repositoryRoot ".build\windows"
$publishDirectory = Join-Path $buildRoot "publish"
$releaseDirectory = Join-Path $buildRoot "release"
$portableStage = Join-Path $buildRoot "portable-stage"
$portableName = "ClassScribe-v$version-windows-x64-portable"
$portableDirectory = Join-Path $portableStage $portableName
$portableArchive = Join-Path $releaseDirectory "$portableName.zip"
$installerName = "ClassScribe-v$version-windows-x64-setup"
$installerPath = Join-Path $releaseDirectory "$installerName.exe"

if (Test-Path -LiteralPath $buildRoot) {
    Remove-Item -LiteralPath $buildRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publishDirectory, $releaseDirectory, $portableDirectory | Out-Null

Push-Location $windowsRoot
try {
    Invoke-NativeCommand dotnet @("restore", $solutionPath, "--locked-mode")
    Invoke-NativeCommand dotnet @("build", $solutionPath, "--configuration", $Configuration, "--no-restore")
    if (-not $SkipTests) {
        Invoke-NativeCommand dotnet @("test", $solutionPath, "--configuration", $Configuration, "--no-build", "--no-restore")
    }
    Invoke-NativeCommand dotnet @(
        "publish", $applicationProject,
        "--configuration", $Configuration,
        "--runtime", $Runtime,
        "--self-contained", "true",
        "--no-restore",
        "--output", $publishDirectory,
        "-p:DebugSymbols=false",
        "-p:DebugType=None"
    )
}
finally {
    Pop-Location
}

$executable = Join-Path $publishDirectory "ClassScribe.exe"
if (-not (Test-Path -LiteralPath $executable)) {
    throw "The self-contained ClassScribe executable was not produced."
}
$executableStream = [System.IO.File]::OpenRead($executable)
try {
    $firstByte = $executableStream.ReadByte()
    $secondByte = $executableStream.ReadByte()
}
finally {
    $executableStream.Dispose()
}
if ($firstByte -ne 0x4d -or $secondByte -ne 0x5a) {
    throw "ClassScribe.exe is not a valid Windows PE executable."
}
if (Get-ChildItem -LiteralPath $publishDirectory -Recurse -File -Filter "*.pdb") {
    throw "Debug symbol files must not be included in a release."
}

# Whisper.net.Runtime currently copies every Windows architecture into a
# framework-dependent subfolder. This release is deliberately win-x64, so keep
# only the matching native runtime and avoid shipping unusable DLLs.
foreach ($unusedRuntime in @("win-arm64", "win-x86")) {
    $unusedRuntimeDirectory = Join-Path $publishDirectory "runtimes\$unusedRuntime"
    if (Test-Path -LiteralPath $unusedRuntimeDirectory) {
        Remove-Item -LiteralPath $unusedRuntimeDirectory -Recurse -Force
    }
}

$requiredNativeFiles = @(
    (Join-Path $publishDirectory "sherpa-onnx-c-api.dll"),
    (Join-Path $publishDirectory "sherpa-onnx.dll"),
    (Join-Path $publishDirectory "runtimes\$Runtime\whisper.dll"),
    (Join-Path $publishDirectory "runtimes\$Runtime\ggml-whisper.dll"),
    (Join-Path $publishDirectory "runtimes\$Runtime\ggml-base-whisper.dll"),
    (Join-Path $publishDirectory "runtimes\$Runtime\ggml-cpu-whisper.dll")
)
foreach ($requiredNativeFile in $requiredNativeFiles) {
    if (-not (Test-Path -LiteralPath $requiredNativeFile -PathType Leaf)) {
        throw "A required native runtime file is missing: $requiredNativeFile"
    }
}

# Exercise the published executable's isolated-worker startup without opening
# the interactive window or downloading models. Missing inputs intentionally
# produce the worker's controlled failure exit code (70).
$smokeStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
$smokeStartInfo.FileName = $executable
$smokeStartInfo.UseShellExecute = $false
$smokeStartInfo.CreateNoWindow = $true
foreach ($argument in @(
        "--classscribe-diarize",
        (Join-Path $buildRoot "missing.wav"),
        (Join-Path $buildRoot "unused.json"),
        (Join-Path $buildRoot "missing-segmentation.onnx"),
        (Join-Path $buildRoot "missing-embedding.onnx")
    )) {
    [void] $smokeStartInfo.ArgumentList.Add($argument)
}
$smoke = [System.Diagnostics.Process]::Start($smokeStartInfo)
if ($null -eq $smoke) {
    throw "Windows could not start the published executable smoke test."
}
$smoke.WaitForExit()
if ($smoke.ExitCode -ne 70) {
    throw "Published executable smoke test returned $($smoke.ExitCode), expected 70."
}
$smoke.Dispose()

Copy-Item -Path (Join-Path $publishDirectory "*") -Destination $portableDirectory -Recurse
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $portableStage,
    $portableArchive,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)
Write-Sha256File -Path $portableArchive

if (-not $SkipInstaller) {
    $innoCompiler = Find-InnoCompiler
    $env:CLASSSCRIBE_VERSION = $version
    $env:CLASSSCRIBE_PUBLISH_DIR = $publishDirectory
    $env:CLASSSCRIBE_RELEASE_DIR = $releaseDirectory
    $env:CLASSSCRIBE_INSTALLER_NAME = $installerName
    try {
        Invoke-NativeCommand $innoCompiler @($installerScript)
    }
    finally {
        Remove-Item Env:\CLASSSCRIBE_VERSION -ErrorAction SilentlyContinue
        Remove-Item Env:\CLASSSCRIBE_PUBLISH_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\CLASSSCRIBE_RELEASE_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:\CLASSSCRIBE_INSTALLER_NAME -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw "Inno Setup did not produce the expected installer."
    }
    Write-Sha256File -Path $installerPath
}

Write-Host "ClassScribe Windows v$version release assets:"
Get-ChildItem -LiteralPath $releaseDirectory -File | Sort-Object Name | ForEach-Object {
    Write-Host "  $($_.FullName)"
}
