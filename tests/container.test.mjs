import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import assert from "node:assert/strict";
import test, { after, before, describe } from "node:test";

import { repositoryRoot } from "./lib/installer.mjs";

const IMAGE = "baudbound-get:test";
const CONTAINER = `baudbound-get-test-${process.pid}`;
const PORT = 18086;
const ORIGIN = `http://127.0.0.1:${PORT}`;

const hasDocker = spawnSync("docker", ["version"], { stdio: "ignore" }).status === 0;

function docker(args, options = {}) {
	return spawnSync("docker", args, { encoding: "utf8", ...options });
}

after(() => {
	if (hasDocker) docker(["rm", "--force", CONTAINER], { stdio: "ignore" });
});

before(async () => {
	if (!hasDocker) return;

	const build = docker(["build", "--file", join(repositoryRoot, "Dockerfile"), "--tag", IMAGE, repositoryRoot]);
	assert.equal(build.status, 0, build.stderr);

	const run = docker([
		"run", "--detach",
		"--name", CONTAINER,
		"--read-only",
		"--cap-drop", "ALL",
		"--security-opt", "no-new-privileges:true",
		"--tmpfs", "/tmp:rw,noexec,nosuid,size=16m,mode=1777",
		"--publish", `127.0.0.1:${PORT}:8080`,
		IMAGE,
	]);
	assert.equal(run.status, 0, run.stderr);

	// The container is ready when it answers, not when docker run returns.
	for (let attempt = 0; attempt < 50; attempt += 1) {
		try {
			const response = await fetch(`${ORIGIN}/healthz`);
			if (response.ok) return;
		} catch {
			// Not listening yet.
		}
		await new Promise((resolve) => setTimeout(resolve, 200));
	}

	const logs = docker(["logs", CONTAINER]);
	throw new Error(`container did not become ready: ${logs.stdout}${logs.stderr}`);
});

describe("the installer endpoints", { skip: !hasDocker }, () => {
	test("reports health", async () => {
		const response = await fetch(`${ORIGIN}/healthz`);

		assert.equal(response.status, 200);
		assert.equal((await response.text()).trim(), "ok");
	});

	for (const platform of ["linux", "windows"]) {
		test(`serves the ${platform} installer exactly as committed`, async () => {
			const response = await fetch(`${ORIGIN}/${platform}`);

			assert.equal(response.status, 200);
			assert.equal(
				await response.text(),
				readFileSync(join(repositoryRoot, "public", platform), "utf8"),
			);
		});
	}

	test("tells caches not to keep the installer", async () => {
		const response = await fetch(`${ORIGIN}/linux`);

		assert.equal(response.headers.get("cache-control"), "no-cache, no-store, must-revalidate");
		assert.equal(response.headers.get("x-content-type-options"), "nosniff");
	});

	test("has nothing else to serve", async () => {
		const response = await fetch(`${ORIGIN}/missing`);

		assert.equal(response.status, 404);
	});

	test("refuses a method other than a read", async () => {
		const response = await fetch(`${ORIGIN}/linux`, { method: "POST" });

		assert.ok(
			[403, 405].includes(response.status),
			`expected the installer to refuse POST, got ${response.status}`,
		);
	});
});
