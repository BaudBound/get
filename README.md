# BaudBound installer service

This repository contains the static installer endpoints served at [get.baudbound.app](https://get.baudbound.app).

The Linux and Windows scripts detect the local platform, download a published package from [BaudBound releases](https://github.com/BaudBound/BaudBound/releases), verify its checksum, and invoke the platform package installer.

## Test

Linux tests require Bash, jq, shellcheck, and Docker.

```bash
bash tests/linux.sh
bash tests/container.sh
```

The Windows installer contract can be tested from PowerShell.

```powershell
./tests/windows.ps1
```
