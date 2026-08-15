import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import test, { after, before, describe } from "node:test";

import { startFixtureServer } from "./lib/fixture-server.mjs";
import {
	createTestDirectory,
	enableDownloads,
	installerSource,
	pauseSeamLiteral,
	runWindowsInstaller,
} from "./lib/installer.mjs";

const VERSION = "9.9.9";
const ASSET = "BaudBound_9.9.9_x64-setup.exe";
const REGISTRY_PATH = "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\BaudBoundInstallerTest";
const isWindowsHost = process.platform === "win32";

const scratch = createTestDirectory();
const root = scratch.directory;
const fixtures = join(root, "fixtures");

after(async () => {
	await server?.close();
	if (isWindowsHost) {
		// -ErrorAction SilentlyContinue hides the message but still fails the
		// call, so the removal is made non-fatal the only way that works.
		powershell(`try { Remove-Item -Path '${REGISTRY_PATH}' -Recurse -Force -ErrorAction Stop } catch {}`);
	}
	scratch.remove();
});

let installer;
let server;
let baseEnvironment;
let releaseTemplate;

function powershell(script) {
	// The exit code of -Command follows the last statement's success state, so
	// every script ends with an explicit one. Without it a swallowed error, or
	// even a cmdlet that merely wrote to the error stream, exits non-zero.
	const result = spawnSync(
		"powershell.exe",
		["-NoProfile", "-NonInteractive", "-Command", `${script}; exit 0`],
		{ encoding: "utf8" },
	);
	if (result.status !== 0) {
		throw new Error(`PowerShell failed: ${result.stdout}${result.stderr}`);
	}
	return result.stdout;
}

function setInstalledVersion(version) {
	powershell(
		`New-Item -Path '${REGISTRY_PATH}' -Force | Out-Null;` +
			`Set-ItemProperty -Path '${REGISTRY_PATH}' -Name DisplayName -Value 'BaudBound';` +
			`Set-ItemProperty -Path '${REGISTRY_PATH}' -Name DisplayVersion -Value '${version}'`,
	);
}

function writeRelease(name, digest) {
	const release = {
		...releaseTemplate,
		assets: [{ ...releaseTemplate.assets[0], digest }],
	};
	writeFileSync(join(fixtures, name), JSON.stringify(release), "utf8");
	return `${server.origin}/${name}`;
}

before(async () => {
	if (!isWindowsHost) return;

	mkdirSync(fixtures, { recursive: true });

	// Any real executable will do; the installer only hashes it and hands the
	// path to the package manager, which the fixture registry stands in for.
	const assetPath = join(fixtures, ASSET);
	copyFileSync(join(process.env.SystemRoot, "System32", "hostname.exe"), assetPath);
	const digest = createHash("sha256").update(readFileSync(assetPath)).digest("hex");

	installer = enableDownloads("windows", root);
	server = await startFixtureServer(fixtures);

	releaseTemplate = {
		tag_name: `v${VERSION}`,
		assets: [{ name: ASSET, browser_download_url: `${server.origin}/${ASSET}`, digest: `sha256:${digest}` }],
	};
	writeFileSync(join(fixtures, "release.json"), JSON.stringify(releaseTemplate), "utf8");

	baseEnvironment = {
		BAUDBOUND_ALLOW_INSECURE_TEST_URL: "1",
		BAUDBOUND_RELEASE_API_URL: `${server.origin}/release.json`,
		BAUDBOUND_UNINSTALL_REGISTRY_PATH: REGISTRY_PATH,
	};
});

async function run(overrides = {}) {
	return runWindowsInstaller(installer, { env: { ...baseEnvironment, ...overrides } });
}

describe("the published installer", { skip: !isWindowsHost }, () => {
	test("refuses while downloads are paused", async () => {
		const paused = join(root, "paused.ps1");
		writeFileSync(paused, readFileSync(installerSource("windows"), "utf8"), "utf8");
		const result = await runWindowsInstaller(paused);

		assert.notEqual(result.status, 0);
		assert.match(result.output, /downloads are paused until the first public app release/);
	});

	test("carries the pause seam the tests rewrite", async () => {
		const source = readFileSync(installerSource("windows"), "utf8");
		assert.ok(source.split(/\r?\n/).includes(pauseSeamLiteral("windows")));
	});
});

describe("installation", { skip: !isWindowsHost }, () => {
	test("installs when nothing newer is present", async () => {
		setInstalledVersion("1.0.0");
		const result = await run();

		assert.equal(result.status, 0, result.output);
	});

	test("reports an installation that is already current", async () => {
		setInstalledVersion(VERSION);
		const result = await run();

		assert.equal(result.status, 0, result.output);
		assert.match(result.output, /already up to date/);
	});
});

describe("refusals", { skip: !isWindowsHost }, () => {
	test("refuses to replace a newer installation", async () => {
		setInstalledVersion("10.0.0");
		const result = await run();

		assert.notEqual(result.status, 0);
		const normalized = result.output.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "").replace(/\s+/g, " ");
		assert.match(normalized, /installed BaudBound 10\.0\.0.*release 9\.9\.9.*Downgrades are not supported/);
	});

	test("refuses malformed installed-version metadata", async () => {
		setInstalledVersion("unknown");
		const result = await run();

		assert.notEqual(result.status, 0);
		assert.match(result.output, /is not valid semantic version metadata/);
	});

	test("refuses a published digest that does not describe the download", async () => {
		setInstalledVersion("1.0.0");
		const feed = writeRelease("release-corrupt.json", `sha256:${"0".repeat(64)}`);
		const result = await run({ BAUDBOUND_RELEASE_API_URL: feed });

		assert.notEqual(result.status, 0);
		assert.match(result.output, /checksum does not match/);
	});
});
