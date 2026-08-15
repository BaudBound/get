import { createReadStream, statSync } from "node:fs";
import { createServer } from "node:http";
import { join, resolve, sep } from "node:path";

/**
 * Serves a directory over loopback so the installer can download from a real
 * URL. The installer only accepts loopback origins when
 * BAUDBOUND_ALLOW_INSECURE_TEST_URL is set, so nothing here weakens the URL
 * rules it applies to a published release.
 */
export async function startFixtureServer(root) {
	const rootPath = resolve(root);

	const server = createServer((request, response) => {
		const requested = new URL(request.url, "http://127.0.0.1").pathname;
		// Both sides are resolved before comparing. Comparing a joined path
		// against the argument as given comes apart when separators differ.
		const path = resolve(join(rootPath, decodeURIComponent(requested).replace(/^[/\\]+/, "")));

		if (!path.startsWith(rootPath + sep) || !statSync(path, { throwIfNoEntry: false })?.isFile()) {
			response.writeHead(404).end();
			return;
		}

		response.writeHead(200, { "content-type": "application/octet-stream" });
		createReadStream(path).pipe(response);
	});

	await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
	// A client that leaves a keep-alive socket open would hold both close() and
	// the event loop open, so the suite would finish its assertions and then
	// hang. Nothing here should outlive the tests.
	server.unref();

	return {
		origin: `http://127.0.0.1:${server.address().port}`,
		async close() {
			server.closeAllConnections();
			await new Promise((resolveClose) => server.close(resolveClose));
		},
	};
}
