# Agent Island for Windows — release build.
# Produces a self-contained single-file exe plus a distributable zip under dist\.
# -Version comes from the shared VERSION file at release time (CI passes it);
# the csproj version is only a dev fallback.
param([string]$Runtime = "win-x64", [string]$Version = "")

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$csproj = "src\AgentIsland\AgentIsland.csproj"
if (-not $Version) { $Version = ([xml](Get-Content $csproj)).Project.PropertyGroup.Version }
if (-not $Version) { $Version = "0.0.0" }
$version = "$Version".Trim()

$publishDir = "dist\publish"
if (Test-Path $publishDir) { Remove-Item $publishDir -Recurse -Force }

& dotnet publish $csproj `
    -c Release `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:Version=$version `
    -o $publishDir
if ($LASTEXITCODE -ne 0) { throw "publish failed" }

$zip = "dist\AgentIsland-$version-$Runtime.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$publishDir\AgentIsland.exe" -DestinationPath $zip

Write-Output "built  $publishDir\AgentIsland.exe"
Write-Output "packed $zip"
