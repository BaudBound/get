import { spawn } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

const PAUSE_SEAM = {
	linux: { find: /^downloads_enabled=0$/m, replace: "downloads_enabled=1", literal: "downloads_enabled=0" },
	windows: { find: /^\$DownloadsEnabled = 0$/m, replace: "$DownloadsEnabled = 1", literal: "$DownloadsEnabled = 0" },
};

export function installerSource(platform) {
	return join(repositoryRoot, "public", platform);
}

/**
 * Creates a scratch directory and returns it with its own cleanup. The caller
 * registers that cleanup at module scope: an `after` registered inside a
 * `before` hook belongs to the hook, and removes the directory before the
 * tests that need it have run.
 */
export function createTestDirectory() {
	const directory = mkdtempSync(join(tmpdir(), "baudbound-installer-test-"));
	return {
		directory,
		remove: () => rmSync(directory, { force: true, recursive: true }),
	};
}

/**
 * The published installer refuses before doing anything. Tests run a copy with
 * that one line flipped, so the logic below the seam is covered without
 * shipping a runtime override on the public endpoint.
 */
export function enableDownloads(platform, directory) {
	const seam = PAUSE_SEAM[platform];
	const source = readFileSync(installerSource(platform), "utf8");

	if (!seam.find.test(source)) {
		throw new Error(`pause seam '${seam.literal}' is missing from the ${platform} installer`);
	}

	const target = join(directory, platform === "windows" ? "installer.ps1" : "installer.sh");
	writeFileSync(target, source.replace(seam.find, seam.replace), "utf8");
	chmodSync(target, 0o755);
	return target;
}

export function pauseSeamLiteral(platform) {
	return PAUSE_SEAM[platform].literal;
}

/**
 * Writes an executable stub onto a directory that later goes on PATH. The stub
 * is Node so the suite carries no shell of its own; `body` receives the
 * process arguments after the stub name.
 */
export function writeCommandStub(binDirectory, name, body) {
	mkdirSync(binDirectory, { recursive: true });
	const path = join(binDirectory, name);
	writeFileSync(
		path,
		`#!/usr/bin/env node\nconst args = process.argv.slice(2);\n${body}\n`,
		"utf8",
	);
	chmodSync(path, 0o755);
	return path;
}

/**
 * Runs the Linux installer under a pseudo-terminal.
 *
 * The installer refuses to continue without one, because APT and DNF prompt for
 * approval. `script` is the portable way to allocate a terminal for a child
 * process without adding a native dependency to this suite.
 */
/**
 * Runs a child and collects its output.
 *
 * Deliberately asynchronous. spawnSync blocks this process's event loop, and
 * the fixture release server runs in this process, so a synchronous child
 * could never receive a response to the request it makes and would wait until
 * something killed it.
 */
function run(file, args, { env, stdin = "ignore" }) {
	return new Promise((resolve) => {
		const child = spawn(file, args, {
			env: { ...process.env, ...env },
			stdio: [stdin, "pipe", "pipe"],
		});

		let output = "";
		child.stdout.on("data", (chunk) => {
			output += chunk;
		});
		child.stderr.on("data", (chunk) => {
			output += chunk;
		});
		child.on("close", (status) => resolve({ status, output }));
		child.on("error", (error) => resolve({ status: null, output: `${output}${error.message}` }));
	});
}

/**
 * Runs the Linux installer under a pseudo-terminal.
 *
 * The installer refuses to continue without one, because APT and DNF prompt for
 * approval. `script` is the portable way to allocate a terminal for a child
 * without adding a native dependency to this suite.
 */
export function runLinuxInstaller(installer, { env = {}, tty = true } = {}) {
	return tty
		? run("script", ["--quiet", "--return", "--command", `sh '${installer}'`, "/dev/null"], { env })
		: run("setsid", ["-w", "sh", installer], { env });
}

export function runWindowsInstaller(installer, { env = {} } = {}) {
	// -NonInteractive with a closed stdin means a prompt fails the test rather
	// than waiting on input that never arrives.
	return run(
		"powershell.exe",
		["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", installer],
		{ env },
	);
}
