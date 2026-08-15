import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import test, { after, before, describe } from "node:test";

import { startFixtureServer } from "./lib/fixture-server.mjs";
import {
	createTestDirectory,
	enableDownloads,
	installerSource,
	pauseSeamLiteral,
	runLinuxInstaller,
	writeCommandStub,
} from "./lib/installer.mjs";

const VERSION = "9.9.9";

const hasCommand = (name) => spawnSync(name, ["--version"], { stdio: "ignore" }).error === undefined;
const canAllocateTerminal = hasCommand("script");
const canDropTerminal = hasCommand("setsid");
const isLinuxHost = process.platform === "linux";

const scratch = createTestDirectory();
const root = scratch.directory;
const fixtures = join(root, "fixtures");
const binDirectory = join(root, "bin");

after(async () => {
	await server?.close();
	scratch.remove();
});

let installer;
let server;
let baseEnvironment;

const packages = {
	"Baudbound_9.9.9_amd64.deb": "test deb package\n",
	"Baudbound-9.9.9-1.x86_64.rpm": "test rpm package\n",
	"Baudbound_9.9.9_arm64.deb": "test arm64 deb package\n",
	"Baudbound-9.9.9-1.aarch64.rpm": "test aarch64 rpm package\n",
};

before(async () => {
	mkdirSync(fixtures, { recursive: true });

	for (const [name, contents] of Object.entries(packages)) {
		writeFileSync(join(fixtures, name), contents, "utf8");
	}

	installer = enableDownloads("linux", root);
	server = await startFixtureServer(fixtures);

	writeFileSync(
		join(fixtures, "release.json"),
		JSON.stringify({
			tag_name: `v${VERSION}`,
			assets: Object.keys(packages).map((name) => ({
				name,
				browser_download_url: `${server.origin}/${name}`,
				digest: `sha256:${createHash("sha256").update(readFileSync(join(fixtures, name))).digest("hex")}`,
			})),
		}),
		"utf8",
	);

	writeStubs();
	writeOsRelease("debian", 'ID=debian\nPRETTY_NAME="Debian GNU/Linux 13"\n');
	writeOsRelease("ubuntu", 'ID=ubuntu\nPRETTY_NAME="Ubuntu"\n');
	writeOsRelease("fedora", 'ID=fedora\nPRETTY_NAME="Fedora Linux"\n');
	writeOsRelease("arch", 'ID=arch\nPRETTY_NAME="Arch Linux"\n');

	baseEnvironment = {
		PATH: `${binDirectory}:/usr/local/bin:/usr/bin:/bin`,
		BAUDBOUND_ALLOW_INSECURE_TEST_URL: "1",
		BAUDBOUND_RELEASE_API_URL: `${server.origin}/release.json`,
		BAUDBOUND_APPIMAGE_PATH: join(root, "no-appimage"),
		BAUDBOUND_APPIMAGE_COMMAND_PATH: join(root, "no-command"),
		BAUDBOUND_APPIMAGE_LAUNCHER_PATH: join(root, "no-launcher"),
		BAUDBOUND_APPIMAGE_IDENTIFIER_LAUNCHER_PATH: join(root, "no-identifier-launcher"),
	};
});

function writeOsRelease(name, contents) {
	writeFileSync(join(root, `${name}-os-release`), contents, "utf8");
}

function osRelease(name) {
	return join(root, `${name}-os-release`);
}

function writeStubs() {
	writeCommandStub(binDirectory, "sudo", `
		const { spawnSync } = require("node:child_process");
		const result = spawnSync(args[0], args.slice(1), { stdio: "inherit" });
		process.exit(result.status ?? 1);
	`);

	writeCommandStub(binDirectory, "uname", `
		if (args[0] === "-s") process.stdout.write((process.env.BAUDBOUND_TEST_UNAME_S || "Linux") + "\\n");
		else if (args[0] === "-m") process.stdout.write((process.env.BAUDBOUND_TEST_UNAME_M || "x86_64") + "\\n");
		else process.exit(1);
	`);

	for (const manager of ["apt", "dnf"]) {
		writeCommandStub(binDirectory, manager, `
			require("node:fs").writeFileSync(process.env.BAUDBOUND_TEST_COMMAND_FILE, args.join(" ") + "\\n");
		`);
	}

	writeCommandStub(binDirectory, "dpkg-query", `
		const installed = process.env.BAUDBOUND_TEST_INSTALLED_VERSION;
		if (!installed) process.exit(1);
		process.stdout.write(installed);
	`);

	// dpkg --compare-versions <current> <operator> <available>
	writeCommandStub(binDirectory, "dpkg", `
		if (args[0] !== "--compare-versions") process.exit(1);
		const [, current, operator, available] = args;
		const rank = (value) => value.split(".").map(Number);
		const compare = () => {
			const [a, b] = [rank(current), rank(available)];
			for (let index = 0; index < 3; index += 1) {
				if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
			}
			return 0;
		};
		const result = compare();
		process.exit((operator === "eq" && result === 0) || (operator === "lt" && result < 0) ? 0 : 1);
	`);

	// dpkg-deb --field <path> <Field>
	writeCommandStub(binDirectory, "dpkg-deb", `
		const [, path, field] = args;
		if (field === "Package") process.stdout.write("baudbound\\n");
		else if (field === "Version") process.stdout.write("${VERSION}\\n");
		else if (field === "Architecture") process.stdout.write(path.endsWith("_arm64.deb") ? "arm64\\n" : "amd64\\n");
		else process.exit(1);
	`);

	// rpm -qp --queryformat <format> <path>, rpm -q --queryformat <format> <name>
	writeCommandStub(binDirectory, "rpm", `
		if (args[0] === "--eval") {
			const installed = process.env.BAUDBOUND_TEST_INSTALLED_VERSION || "";
			const available = process.env.BAUDBOUND_AVAILABLE_VERSION || "";
			const rank = (value) => value.split(".").map(Number);
			const [a, b] = [rank(installed), rank(available)];
			let verdict = 0;
			for (let index = 0; index < 3; index += 1) {
				if (a[index] !== b[index]) { verdict = a[index] < b[index] ? -1 : 1; break; }
			}
			process.stdout.write(String(verdict));
			process.exit(0);
		}
		const [mode, , format, target] = args;
		const installed = process.env.BAUDBOUND_TEST_INSTALLED_VERSION;
		if (format === "%{NAME}" && mode === "-qp") process.stdout.write("baudbound");
		else if (format === "%{VERSION}" && mode === "-qp") process.stdout.write("${VERSION}");
		else if (format === "%{VERSION}" && mode === "-q" && installed) process.stdout.write(installed);
		else if (format === "%{ARCH}" && mode === "-qp") process.stdout.write(target.endsWith(".aarch64.rpm") ? "aarch64" : "x86_64");
		else if (mode === "-q" && installed) process.stdout.write(installed);
		else process.exit(1);
	`);
}

async function run(overrides = {}, options = {}) {
	return runLinuxInstaller(installer, { env: { ...baseEnvironment, ...overrides }, ...options });
}

function commandFile(name) {
	return join(root, `${name}-command`);
}

describe("the published installer", () => {
	test("refuses while downloads are paused", async () => {
		const result = spawnSync("sh", [installerSource("linux")], { encoding: "utf8" });
		assert.notEqual(result.status, 0);
		assert.match(
			`${result.stdout}${result.stderr}`,
			/downloads are paused until the first public app release/,
		);
	});

	test("carries the pause seam the tests rewrite", async () => {
		const source = readFileSync(installerSource("linux"), "utf8");
		assert.ok(source.split(/\r?\n/).includes(pauseSeamLiteral("linux")));
	});
});

describe("dependencies", { skip: !isLinuxHost }, () => {
	test("stops when a required command is missing", async () => {
		const empty = join(root, "empty-path");
		mkdirSync(empty, { recursive: true });
		const result = await run({ PATH: empty }, { tty: false });

		assert.notEqual(result.status, 0);
		assert.match(result.output, /required commands are missing/);
		assert.match(result.output, /No files were downloaded or installed/);
	});
});

describe("architecture and distribution selection", { skip: !canAllocateTerminal }, () => {
	const selections = [
		{ distribution: "debian", machine: "x86_64", expect: /Baudbound_9\.9\.9_amd64\.deb$/, banner: "Detected Debian GNU/Linux 13" },
		{ distribution: "ubuntu", machine: "x86_64", expect: /Baudbound_9\.9\.9_amd64\.deb$/, banner: "Detected Ubuntu" },
		{ distribution: "fedora", machine: "x86_64", expect: /Baudbound-9\.9\.9-1\.x86_64\.rpm$/, banner: "Detected Fedora Linux" },
		{ distribution: "debian", machine: "aarch64", expect: /Baudbound_9\.9\.9_arm64\.deb$/, banner: "on 64-bit aarch64 Linux" },
		{ distribution: "fedora", machine: "aarch64", expect: /Baudbound-9\.9\.9-1\.aarch64\.rpm$/, banner: "on 64-bit aarch64 Linux" },
		// arm64 is the same machine reported under another name.
		{ distribution: "debian", machine: "arm64", expect: /Baudbound_9\.9\.9_arm64\.deb$/, banner: "on 64-bit aarch64 Linux" },
	];

	for (const { distribution, machine, expect, banner } of selections) {
		test(`${distribution} on ${machine} installs the matching package`, async () => {
			const recorded = commandFile(`${distribution}-${machine}`);
			rmSync(recorded, { force: true });

			const result = await run({
				BAUDBOUND_OS_RELEASE_FILE: osRelease(distribution),
				BAUDBOUND_TEST_COMMAND_FILE: recorded,
				BAUDBOUND_TEST_UNAME_M: machine,
			});

			assert.equal(result.status, 0, result.output);
			assert.match(result.output, new RegExp(banner.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
			assert.match(readFileSync(recorded, "utf8").trim(), expect);
		});
	}

	for (const machine of ["armv7l", "i686", "riscv64"]) {
		test(`refuses ${machine}`, async () => {
			const result = await run({
				BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
				BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
				BAUDBOUND_TEST_UNAME_M: machine,
			});

			assert.notEqual(result.status, 0);
			assert.match(result.output, /only 64-bit x86 and ARM Linux are currently supported/);
		});
	}

	test("refuses an untested distribution without downloading", async () => {
		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("arch"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
		});

		assert.notEqual(result.status, 0);
		assert.match(result.output, /Arch Linux is not supported by the automatic installer/);
		assert.match(result.output, /No files were downloaded or installed/);
	});
});

describe("os-release parsing", { skip: !canAllocateTerminal }, () => {
	const accepted = [
		["unquoted", "ID=debian\n"],
		["double quoted", 'ID="debian"\n'],
		["single quoted", "ID='debian'\n"],
		["with other keys", 'NAME="Whatever"\nID=debian\nVERSION_ID="13"\n'],
	];

	for (const [label, contents] of accepted) {
		test(`reads an ${label} identifier`, async () => {
			const path = join(root, `os-release-${label.replace(/\s+/g, "-")}`);
			writeFileSync(path, contents, "utf8");
			const recorded = commandFile(`parse-${label.replace(/\s+/g, "-")}`);
			rmSync(recorded, { force: true });

			const result = await run({
				BAUDBOUND_OS_RELEASE_FILE: path,
				BAUDBOUND_TEST_COMMAND_FILE: recorded,
			});

			assert.equal(result.status, 0, result.output);
			assert.match(readFileSync(recorded, "utf8").trim(), /Baudbound_9\.9\.9_amd64\.deb$/);
		});
	}

	test("refuses a file with no identifier", async () => {
		const path = join(root, "os-release-anonymous");
		writeFileSync(path, 'NAME="No identifier here"\n', "utf8");

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: path,
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
		});

		assert.notEqual(result.status, 0);
		assert.match(result.output, /identifier in .* is invalid/);
	});

	// Regression guard for the rule that os-release is read, never sourced. The
	// installer parses, so the substitution below is literal text and the
	// character check refuses it. Were it sourced, the marker would appear.
	// Asserting the refusal alone would not catch that: a sourced file also
	// fails to identify the system, for a different reason.
	test("does not execute the file it reads", async () => {
		const marker = join(root, "os-release-was-executed");
		const path = join(root, "os-release-hostile");
		writeFileSync(path, `ID=debian$(touch ${marker})\n`, "utf8");

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: path,
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
		});

		assert.notEqual(result.status, 0);
		assert.equal(existsSync(marker), false, "os-release was executed rather than parsed");
	});
});

describe("version handling", { skip: !canAllocateTerminal }, () => {
	test("reports an installation that is already current", async () => {
		const recorded = commandFile("already-current");
		rmSync(recorded, { force: true });

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
			BAUDBOUND_TEST_COMMAND_FILE: recorded,
			BAUDBOUND_TEST_INSTALLED_VERSION: VERSION,
			BAUDBOUND_AVAILABLE_VERSION: VERSION,
		});

		assert.equal(result.status, 0, result.output);
		assert.match(result.output, /is already installed and up to date/);
		assert.equal(existsSync(recorded), false, "package manager ran for an already current package");
	});

	test("describes an upgrade as an update", async () => {
		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("update"),
			BAUDBOUND_TEST_INSTALLED_VERSION: "9.8.0",
			BAUDBOUND_AVAILABLE_VERSION: VERSION,
		});

		assert.equal(result.status, 0, result.output);
		assert.match(result.output, /Updating BaudBound from 9\.8\.0 to 9\.9\.9 with APT/);
	});

	test("refuses to replace a newer installation", async () => {
		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("downgrade"),
			BAUDBOUND_TEST_INSTALLED_VERSION: "10.0.0",
			BAUDBOUND_AVAILABLE_VERSION: VERSION,
		});

		assert.notEqual(result.status, 0);
		assert.match(result.output, /is newer than release 9\.9\.9/);
		assert.match(result.output, /Downgrades are not supported/);
	});
});

describe("refusals", { skip: !canAllocateTerminal }, () => {
	test("stops when an existing AppImage installation is present", async () => {
		const appImage = join(root, "BaudBound.AppImage");
		writeFileSync(appImage, "old AppImage\n", "utf8");

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("appimage"),
			BAUDBOUND_APPIMAGE_PATH: appImage,
		});

		rmSync(appImage, { force: true });
		assert.notEqual(result.status, 0);
		assert.match(result.output, /an existing AppImage installation was found/);
		assert.match(result.output, /No files were downloaded or installed/);
	});

	test("stops when the release has no package for the architecture", async () => {
		const release = JSON.parse(readFileSync(join(fixtures, "release.json"), "utf8"));
		const withoutDebs = {
			...release,
			assets: release.assets.filter((asset) => !asset.name.endsWith(".deb")),
		};
		writeFileSync(join(fixtures, "release-no-deb.json"), JSON.stringify(withoutDebs), "utf8");

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("ubuntu"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
			BAUDBOUND_RELEASE_API_URL: `${server.origin}/release-no-deb.json`,
		});

		assert.notEqual(result.status, 0);
		assert.match(result.output, /exactly one deb package for amd64/);
	});

	test("stops when the published digest does not describe the download", async () => {
		const release = JSON.parse(readFileSync(join(fixtures, "release.json"), "utf8"));
		const corrupted = {
			...release,
			assets: release.assets.map((asset) =>
				asset.name.endsWith("_amd64.deb") ? { ...asset, digest: `sha256:${"0".repeat(64)}` } : asset,
			),
		};
		writeFileSync(join(fixtures, "release-corrupt.json"), JSON.stringify(corrupted), "utf8");

		const result = await run({
			BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
			BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
			BAUDBOUND_RELEASE_API_URL: `${server.origin}/release-corrupt.json`,
		});

		assert.notEqual(result.status, 0);
		assert.match(result.output, /checksum does not match/);
	});
});

describe("terminal requirement", { skip: !canDropTerminal }, () => {
	test("refuses to run without an interactive terminal", async () => {
		const result = await run(
			{
				BAUDBOUND_OS_RELEASE_FILE: osRelease("debian"),
				BAUDBOUND_TEST_COMMAND_FILE: commandFile("unused"),
			},
			{ tty: false },
		);

		assert.notEqual(result.status, 0);
		assert.match(result.output, /an interactive terminal is required/);
	});
});
