$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$wapproj = Join-Path $root "src\cascadia\CascadiaPackage\CascadiaPackage.wapproj"
$pfxPath = Join-Path $root "src\cascadia\CascadiaPackage\CascadiaPackage_TemporaryKey.pfx"
$certSubject = "CN=wheybags"
$uninstallLine = 'Get-AppxPackage WindowsTerminalDev | Remove-AppxPackage -ErrorAction SilentlyContinue'

function Find-VSTool
{
    param([string]$RelativePath, [string[]]$Fallbacks)

    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere)
    {
        $vsInstallPath = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vsInstallPath)
        {
            $candidate = Join-Path $vsInstallPath $RelativePath
            if (Test-Path $candidate)
            {
                return $candidate
            }
        }
    }

    foreach ($fallback in $Fallbacks)
    {
        if (Test-Path $fallback)
        {
            return $fallback
        }
    }

    throw "Could not locate $RelativePath"
}

function Find-MSBuild
{
    return Find-VSTool -RelativePath "MSBuild\Current\Bin\amd64\MSBuild.exe" -Fallbacks @(
        "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\amd64\MSBuild.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\amd64\MSBuild.exe")
}

function Find-DevEnv
{
    return Find-VSTool -RelativePath "Common7\IDE\devenv.com" -Fallbacks @(
        "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\devenv.com",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.com")
}

winget configure --enable
if ($LASTEXITCODE -ne 0)
{
    throw "winget configure --enable failed with exit code $LASTEXITCODE"
}

winget configure (Join-Path $root ".config\configuration.winget") --accept-configuration-agreements
if ($LASTEXITCODE -ne 0)
{
    throw "winget configure failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $pfxPath))
{
    Write-Host "No signing certificate found, generating one at $pfxPath"
    $cert = New-SelfSignedCertificate -Type Custom -Subject $certSubject `
        -KeyUsage DigitalSignature -FriendlyName "WindowsTerminalDev local signing cert" `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")

    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password (New-Object System.Security.SecureString) | Out-Null
    Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)"
}

$globalNuget = Join-Path $root "dep\nuget\nuget.exe"
$globalPackagesConfig = Join-Path $root "dep\nuget\packages.config"

& $globalNuget install $globalPackagesConfig -OutputDirectory (Join-Path $root "packages")
if ($LASTEXITCODE -ne 0)
{
    throw "NuGet restore of $globalPackagesConfig failed with exit code $LASTEXITCODE"
}

$devenv = Find-DevEnv
$slnx = Join-Path $root "OpenConsole.slnx"

& $devenv $slnx /Build "Release|x64" /Project "src\cascadia\WindowsTerminal\WindowsTerminal.vcxproj"
if ($LASTEXITCODE -ne 0)
{
    throw "Build failed with exit code $LASTEXITCODE"
}

$msbuild = Find-MSBuild

& $msbuild $wapproj /p:Configuration=Release /p:Platform=x64 /p:SolutionDir="$root\" /nologo /v:minimal /m
if ($LASTEXITCODE -ne 0)
{
    throw "Packaging failed with exit code $LASTEXITCODE"
}

$installScript = Get-ChildItem -Path (Join-Path $root "bin\AppPackages") -Filter "Install.ps1" -Recurse |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $installScript)
{
    throw "Could not find Install.ps1 under bin\AppPackages after build"
}

$content = Get-Content $installScript.FullName -Raw

if ($content -notmatch [regex]::Escape($uninstallLine))
{
    $content = $content -replace '(?s)^(.*?param\s*\([^)]*\)\s*\r?\n)', "`$1$uninstallLine`r`n"
    Set-Content -Path $installScript.FullName -Value $content -NoNewline
}

$installBatPath = Join-Path $installScript.DirectoryName "install.bat"
$installBat = @'
@echo off
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Install.ps1\"'"
'@
Set-Content -Path $installBatPath -Value $installBat -Encoding ASCII

Write-Host "Package built: $($installScript.FullName)"
Write-Host "Installer: $installBatPath"
