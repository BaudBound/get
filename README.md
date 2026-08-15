# BaudBound installer service

This repository contains the static installer endpoints served at [get.baudbound.app](https://get.baudbound.app).

The Linux and Windows scripts detect the local platform, download a published package from [BaudBound releases](https://github.com/BaudBound/baudbound/releases), verify its checksum, and invoke the platform package installer.

## Test

The suite is Node, using the built-in test runner. It drives the installers as real processes and serves their release metadata from an in-process fixture server.

```bash
npm test
```

Each file can be run on its own:

```bash
node --test tests/linux.test.mjs
node --test tests/windows.test.mjs
node --test tests/container.test.mjs
```

Cases that need tooling the host does not have are skipped rather than failed, so the same command is useful everywhere. The Linux installer tests need `script` for a pseudo-terminal and `setsid` to withhold one; the container tests need Docker; the Windows tests need Windows.
