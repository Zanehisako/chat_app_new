import { webhookEventTimestamp } from "./event_time.ts";

Deno.test("LiveKit bigint webhook timestamps are normalized", () => {
  const result = webhookEventTimestamp(
    1_783_956_900n,
    new Date("2026-01-01T00:00:00.000Z"),
  );
  if (result !== "2026-07-13T15:35:00.000Z") {
    throw new Error(`Unexpected webhook timestamp: ${result}`);
  }
});

Deno.test("invalid webhook timestamps use the receipt time", () => {
  const fallback = new Date("2026-07-13T16:00:00.000Z");
  if (webhookEventTimestamp("invalid", fallback) !== fallback.toISOString()) {
    throw new Error("Invalid webhook timestamp did not use the receipt time.");
  }
});
