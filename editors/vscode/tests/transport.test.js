/**
 * Headless integration test for the Ragex transport layer.
 *
 * Runs the compiled client outside the VS Code host, so it exercises the real
 * socket / stdio transports against a live Ragex server.
 *
 *   node tests/transport.test.js
 */
const fs = require("fs");
const path = require("path");
const { RagexClient } = require("../out/transport/client");
const { computeSocketPath } = require("../out/transport/socketPath");
const { unwrap, searchResults } = require("../out/response");

const root = path.resolve(__dirname, "..", "..", "..");
const bin = path.join(root, "bin", "ragex-mcp");

let failures = 0;
function check(name, cond, extra) {
  if (cond) {
    console.log("ok   - " + name);
  } else {
    failures++;
    console.log("FAIL - " + name + (extra ? " :: " + extra : ""));
  }
}

function makeClient(transport) {
  return new RagexClient(
    () => {},
    () => ({
      transport,
      binPath: bin,
      projectRoot: root,
      logLevel: "info",
      requestTimeout: 60000,
    })
  );
}

async function testTransport(transport) {
  const client = makeClient(transport);
  try {
    const result = await client.callTool("graph_stats", {}, { timeout: 60000 });
    const data = unwrap(result);
    check(
      `${transport}: graph_stats round-trip`,
      data && typeof data === "object",
      JSON.stringify(data).slice(0, 120)
    );
    check(`${transport}: transport kind`, client.transportKind !== null, client.transportKind);
  } catch (err) {
    check(`${transport}: graph_stats round-trip`, false, JSON.stringify(err));
  } finally {
    client.close();
  }
}

async function main() {
  console.log("socket path:", computeSocketPath(root));

  await testTransport("auto");
  await testTransport("socket");
  await testTransport("stdio");

  if (failures === 0) {
    console.log("ALL PASS");
    process.exit(0);
  } else {
    console.log(failures + " FAILURE(S)");
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("fatal:", err);
  process.exit(1);
});
