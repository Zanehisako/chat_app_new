import { createDispatchHandler, isValidWnsChannelUri } from "./index.ts";

Deno.test("dispatcher fails closed before claiming jobs", async () => {
  const handler = createDispatchHandler({
    env: () => undefined,
  });
  const response = await handler(new Request("https://example.test", { method: "POST" }));
  if (response.status !== 500) {
    throw new Error(`Expected 500 for a missing secret, got ${response.status}.`);
  }
});

Deno.test("dispatcher rejects the wrong secret and non-POST requests", async () => {
  const handler = createDispatchHandler({
    env: (name) => name === "NOTIFICATION_DISPATCH_SECRET"
      ? "a-very-long-test-dispatch-secret-value"
      : undefined,
  });
  const wrongSecret = await handler(new Request("https://example.test", {
    method: "POST",
    headers: { "x-dispatch-secret": "wrong" },
  }));
  const get = await handler(new Request("https://example.test", { method: "GET" }));
  if (wrongSecret.status !== 401 || get.status !== 405) {
    throw new Error("Dispatcher accepted an unauthorized invocation.");
  }
});

Deno.test("dispatcher completes an authenticated empty batch", async () => {
  const secret = "a-very-long-test-dispatch-secret-value";
  const rpcCalls: string[] = [];
  const handler = createDispatchHandler({
    env: (name) => name === "NOTIFICATION_DISPATCH_SECRET" ? secret : undefined,
    supabase: {
      rpc(name: string) {
        rpcCalls.push(name);
        return Promise.resolve({ data: [], error: null });
      },
    } as never,
  });
  const response = await handler(new Request("https://example.test", {
    method: "POST",
    headers: { "x-dispatch-secret": secret },
  }));
  if (response.status !== 200 || rpcCalls.join(",") !==
      "drop_empty_push_notification_jobs,claim_push_notification_deliveries") {
    throw new Error("Dispatcher did not run the expected authenticated claim path.");
  }
});

Deno.test("WNS only accepts HTTPS Microsoft channel hosts", () => {
  if (!isValidWnsChannelUri("https://example.notify.windows.com/channel")) {
    throw new Error("Expected a Microsoft HTTPS WNS endpoint to be accepted.");
  }
  if (isValidWnsChannelUri("http://example.notify.windows.com/channel") ||
      isValidWnsChannelUri("https://notify.windows.com.evil.test/channel")) {
    throw new Error("Rejected WNS endpoint validation accepted an unsafe URI.");
  }
});
