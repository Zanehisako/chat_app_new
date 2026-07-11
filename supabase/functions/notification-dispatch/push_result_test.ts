import {
  fcmResponseResult,
  retryDecision,
  wnsResponseResult,
} from "./push_result.ts";

Deno.test("FCM success and invalid-token responses", () => {
  const success = fcmResponseResult(200, '{"name":"projects/demo/messages/1"}');
  const invalid = fcmResponseResult(404, '{"status":"UNREGISTERED"}');

  if (!success.ok) throw new Error("Expected FCM success.");
  if (invalid.ok || !invalid.invalidToken || invalid.retryable) {
    throw new Error("Expected an invalid, non-retryable FCM token.");
  }
});

Deno.test("FCM and WNS transient failures back off", () => {
  const fcm = fcmResponseResult(503, "unavailable");
  const wns = wnsResponseResult(429);

  if (!fcm.retryable || !wns.retryable) {
    throw new Error("Expected transient provider failures to retry.");
  }
});

Deno.test("WNS invalid channels and max attempts are terminal", () => {
  const invalidWns = wnsResponseResult(410);
  const retry = retryDecision(3, 0);
  const terminal = retryDecision(8, 0);

  if (!invalidWns.invalidToken || invalidWns.retryable) {
    throw new Error("Expected a retired WNS channel to be disabled.");
  }
  if (retry.status !== "retry" || terminal.status !== "failed") {
    throw new Error("Unexpected retry/dead-letter decision.");
  }
});
