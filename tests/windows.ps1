$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$InstallerSource = Join-Path $RepositoryRoot "public/windows"
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("baudbound-windows-installer-test-" + [Guid]::NewGuid())
$FixtureRoot = Join-Path $TestRoot "fixture"
$RegistryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\BaudBoundInstallerTest"
$Server = $null
$PowerShellExecutable = (Get-Process -Id $PID).Path

function Get-AvailablePort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

try {
    Write-Host "Preparing Windows installer fixture..."
    New-Item -ItemType Directory -Path $FixtureRoot | Out-Null

    # The published installer refuses before doing anything. Everything below is
    # tested against a copy with that one line flipped, so the logic is covered
    # without shipping a runtime override on the public endpoint.
    # PowerShell only runs a file named .ps1, and the installer is served from a
    # path without an extension, so both the paused and enabled runs use copies.
    $PausedInstaller = Join-Path $TestRoot "installer-paused.ps1"
    Copy-Item -LiteralPath $InstallerSource -Destination $PausedInstaller
    $PausedErrorPath = Join-Path $TestRoot "paused.err"
    # Stderr goes to a file rather than through 2>&1. Windows PowerShell wraps
    # each stderr line from a native command in an ErrorRecord, which this
    # script's Stop preference would treat as fatal before the check below runs.
    $PausedProcess = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $PausedInstaller
    ) -NoNewWindow -Wait -PassThru -RedirectStandardError $PausedErrorPath
    if ($PausedProcess.ExitCode -eq 0) {
        throw "installer continued while downloads are paused"
    }
    $PausedOutput = Get-Content -LiteralPath $PausedErrorPath -Raw
    if ($PausedOutput -notmatch "downloads are paused until the first public app release") {
        throw "paused installer did not explain why it stopped"
    }

    $InstallerSourceText = Get-Content -LiteralPath $InstallerSource -Raw
    if ($InstallerSourceText -notmatch '(?m)^\$DownloadsEnabled = 0$') {
        throw "pause seam '`$DownloadsEnabled = 0' is missing from the installer"
    }

    $Installer = Join-Path $TestRoot "installer.ps1"
    ($InstallerSourceText -replace '(?m)^\$DownloadsEnabled = 0$', '$DownloadsEnabled = 1') |
        Set-Content -LiteralPath $Installer -Encoding utf8
    $AssetName = "BaudBound_9.9.9_x64-setup.exe"
    $AssetPath = Join-Path $FixtureRoot $AssetName
    Copy-Item -LiteralPath "$env:SystemRoot\System32\hostname.exe" -Destination $AssetPath
    $Digest = (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant()

    New-Item -Path $RegistryPath -Force | Out-Null
    Set-ItemProperty -Path $RegistryPath -Name DisplayName -Value "BaudBound"
    Set-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value "1.0.0"
    Write-Host "Fixture files and registry are ready."

    $Port = Get-AvailablePort
    Write-Host "Starting fixture server on port $Port..."
    $ServerScript = Join-Path $RepositoryRoot "tests/http-server.ps1"
    $Server = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $ServerScript, "-Port", $Port, "-Root", $FixtureRoot
    ) -WindowStyle Hidden -PassThru

    $BaseUrl = "http://127.0.0.1:$Port"
    $Release = @{
        tag_name = "v9.9.9"
        assets = @(
            @{
                name = $AssetName
                browser_download_url = "$BaseUrl/$AssetName"
                digest = "sha256:$Digest"
            }
        )
    } | ConvertTo-Json -Depth 4
    $ReleasePath = Join-Path $FixtureRoot "release.json"
    [IO.File]::WriteAllText($ReleasePath, $Release, [Text.UTF8Encoding]::new($false))
    Write-Host "Waiting for fixture server..."
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri "$BaseUrl/release.json" -UseBasicParsing -TimeoutSec 2
            $servedRelease = $response.Content | ConvertFrom-Json
            if ([string]$servedRelease.tag_name -ne "v9.9.9") {
                throw "fixture server returned invalid release metadata: $($response.Content)"
            }
            break
        } catch {
            if ($attempt -eq 49) { throw }
            Start-Sleep -Milliseconds 100
        }
    }

    $env:BAUDBOUND_ALLOW_INSECURE_TEST_URL = "1"
    $env:BAUDBOUND_RELEASE_API_URL = "$BaseUrl/release.json"
    $env:BAUDBOUND_UNINSTALL_REGISTRY_PATH = $RegistryPath

    Write-Host "Testing installation path..."
    & $PowerShellExecutable -NoProfile -File $Installer
    if ($LASTEXITCODE -ne 0) {
        throw "Windows installer update fixture failed"
    }

    Write-Host "Testing current-version path..."
    Set-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value "9.9.9"
    Remove-Item -LiteralPath $AssetPath
    $upToDateOutput = & $PowerShellExecutable -NoProfile -File $Installer 2>&1
    if ($LASTEXITCODE -ne 0 -or $upToDateOutput -notmatch "already up to date") {
        throw "Windows installer did not skip the current version"
    }

    Write-Host "Testing downgrade rejection..."
    Set-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value "10.0.0"
    $DowngradeErrorPath = Join-Path $TestRoot "downgrade.err"
    $DowngradeProcess = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $Installer
    ) -RedirectStandardError $DowngradeErrorPath -Wait -PassThru
    if ($DowngradeProcess.ExitCode -eq 0) {
        throw "Windows installer accepted a package downgrade"
    }
    $DowngradeError = Get-Content -Raw $DowngradeErrorPath
    $NormalizedDowngradeError = ($DowngradeError -replace '\x1B\[[0-?]*[ -/]*[@-~]', '') -replace '\s+', ' '
    if ($NormalizedDowngradeError -notmatch "installed BaudBound 10.0.0.*release 9.9.9.*Downgrades are not supported") {
        throw "Windows installer did not report the rejected downgrade"
    }

    Write-Host "Testing malformed installed-version rejection..."
    Set-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value "unknown"
    $MalformedVersionErrorPath = Join-Path $TestRoot "malformed-version.err"
    $MalformedVersionProcess = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $Installer
    ) -RedirectStandardError $MalformedVersionErrorPath -Wait -PassThru
    if ($MalformedVersionProcess.ExitCode -eq 0) {
        throw "Windows installer accepted malformed installed-version metadata"
    }
    if ((Get-Content -Raw $MalformedVersionErrorPath) -notmatch "is not valid semantic version metadata") {
        throw "Windows installer did not report malformed installed-version metadata"
    }

    Write-Host "Testing corrupt-digest rejection..."
    Copy-Item -LiteralPath "$env:SystemRoot\System32\hostname.exe" -Destination $AssetPath
    $ReleaseObject = $Release | ConvertFrom-Json
    $ReleaseObject.assets[0].digest = "sha256:$('0' * 64)"
    [IO.File]::WriteAllText(
        $ReleasePath,
        ($ReleaseObject | ConvertTo-Json -Depth 4),
        [Text.UTF8Encoding]::new($false)
    )
    Set-ItemProperty -Path $RegistryPath -Name DisplayVersion -Value "1.0.0"
    $CorruptErrorPath = Join-Path $TestRoot "corrupt.err"
    $CorruptProcess = Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        "-NoProfile", "-File", $Installer
    ) -RedirectStandardError $CorruptErrorPath -Wait -PassThru
    if ($CorruptProcess.ExitCode -eq 0) {
        throw "Windows installer accepted a corrupt checksum"
    }
    if ((Get-Content -Raw $CorruptErrorPath) -notmatch "checksum does not match") {
        throw "Windows installer did not report the corrupt checksum"
    }

    Write-Host "Windows installer tests passed."
} finally {
    Write-Host "Cleaning Windows installer fixture..."
    if ($null -ne $Server -and -not $Server.HasExited) {
        Stop-Process -Id $Server.Id -Force
        $Server.WaitForExit()
    }
    Remove-Item -Path $RegistryPath -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:BAUDBOUND_ALLOW_INSECURE_TEST_URL -ErrorAction SilentlyContinue
    Remove-Item Env:BAUDBOUND_RELEASE_API_URL -ErrorAction SilentlyContinue
    Remove-Item Env:BAUDBOUND_UNINSTALL_REGISTRY_PATH -ErrorAction SilentlyContinue
}
