import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createClient } from "rivetkit/client";

const client = createClient({
  endpoint: process.env.RIVET_ENDPOINT ?? "http://127.0.0.1:6420",
  token: process.env.RIVET_TOKEN ?? "dev",
  namespace: "default",
  poolName: "default",
  devtools: false,
});

try {
  const counter = client.counter.getOrCreate(["typescript-interop", randomUUID()]);
  assert.equal(await counter.increment(7), 7);
  const connection = counter.connect();
  const event = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("event not received")), 5000);
    connection.once("newCount", (count) => {
      clearTimeout(timer);
      resolve(count);
    });
  });
  assert.equal(await connection.increment(4), 11);
  assert.equal(await event, 11);
  assert.equal(await counter.count(), 11);

  const actor = client.kitchen_sink.getOrCreate(["typescript-json", randomUUID()]);
  const value = { text: "日本語 🦀", nested: [false, null, 3.25] };
  assert.deepEqual(await actor.echo(value, [1, 2], null), [value, [1, 2], null]);
  const queue = await actor.send("double", { value: 21 }, { wait: true, timeout: 3000 });
  assert.equal(queue.status, "completed");
  assert.equal(queue.response, 42);
  console.log("TypeScript → Ruby: HTTP actions, WebSocket actions/events, JSON and queue replies passed");
} finally {
  await client.dispose();
}
