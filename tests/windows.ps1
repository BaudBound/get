$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$InstallerSource = Join-Path $RepositoryRoot "public/windows"
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("baudbound-windows-installer-test-" + [Guid]::NewGuid())
$PowerShellExecutable = (Get-Process -Id $PID).Path

try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    $Installer = Join-Path $TestRoot "installer.ps1"
    Copy-Item -LiteralPath $InstallerSource -Destination $Installer
    $ErrorPath = Join-Path $TestRoot "unpublished.err"
    $Process = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $Installer
    ) -RedirectStandardError $ErrorPath -Wait -PassThru

    if ($Process.ExitCode -eq 0) {
        throw "Windows installer continued before the public app release"
    }

    $ErrorOutput = Get-Content -Raw $ErrorPath
    if ($ErrorOutput -notmatch "downloads are paused until the first public app release") {
        throw "Windows installer did not report the temporary release notice"
    }
    if ($ErrorOutput -notmatch "https://github.com/BaudBound/baudbound") {
        throw "Windows installer did not include the development link"
    }

    Write-Host "Windows installer temporary release notice test passed."
} finally {
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
