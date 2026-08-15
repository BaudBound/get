import { spawn, spawnSync } from "node:child_process";
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
/**
 * @param mode
 *   "terminal" runs under a pseudo-terminal, which the installer requires
 *   because APT and DNF prompt for approval.
 *   "no-terminal" withholds one, to prove the installer refuses.
 *   "direct" runs it with neither wrapper, for cases that alter PATH: the
 *   wrappers are themselves resolved through PATH, so a test that empties it
 *   would fail to launch rather than testing the installer.
 */
export function runLinuxInstaller(installer, { env = {}, mode = "terminal" } = {}) {
	// Absolute, because "direct" exists for cases that empty PATH and a bare
	// name would be resolved through the very PATH under test.
	if (mode === "direct") return run("/bin/sh", [installer], { env });
	if (mode === "no-terminal") return run("setsid", ["-w", "sh", installer], { env });
	return run("script", ["--quiet", "--return", "--command", `sh '${installer}'`, "/dev/null"], { env });
}

/**
 * PowerShell 7 where it exists, Windows PowerShell otherwise. The two differ in
 * which cmdlets they carry, and the installer uses some that the oldest
 * Windows PowerShell does not have, so the newer one is preferred rather than
 * assumed absent.
 */
export const powerShellExecutable = (() => {
	const candidates = process.platform === "win32" ? ["pwsh.exe", "powershell.exe"] : ["pwsh"];
	return (
		candidates.find((candidate) => {
			const probe = spawnSync(candidate, ["-NoProfile", "-Command", "exit 0"], { stdio: "ignore" });
			return probe.error === undefined && probe.status === 0;
		}) ?? candidates.at(-1)
	);
})();

export function runWindowsInstaller(installer, { env = {} } = {}) {
	// -NonInteractive with a closed stdin means a prompt fails the test rather
	// than waiting on input that never arrives.
	return run(
		powerShellExecutable,
		["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", installer],
		{ env },
	);
}
