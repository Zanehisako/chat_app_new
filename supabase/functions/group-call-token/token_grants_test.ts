import { AccessToken } from "npm:livekit-server-sdk@2.17.0";
import { allowedPublishSources } from "./token_grants.ts";

Deno.test("group call publish grants produce valid short-lived tokens", async () => {
  for (
    const testCase of [
      { isVideo: false, expected: ["microphone"] },
      { isVideo: true, expected: ["microphone", "camera"] },
    ]
  ) {
    const token = new AccessToken(
      "test-api-key",
      "test-api-secret-that-is-long-enough-for-signing",
      { identity: "test-user", ttl: "60s" },
    );
    token.addGrant({
      roomJoin: true,
      room: "test-room",
      canPublish: true,
      canSubscribe: true,
      canPublishSources: allowedPublishSources(testCase.isVideo),
    });

    const payload = decodePayload(await token.toJwt());
    if (
      payload.video?.room !== "test-room" ||
      JSON.stringify(payload.video?.canPublishSources) !==
        JSON.stringify(testCase.expected)
    ) {
      throw new Error(
        `Unexpected group-call token grant: ${JSON.stringify(payload.video)}`,
      );
    }
  }
});

function decodePayload(token: string): Record<string, any> {
  const encoded = token.split(".")[1];
  const normalized = encoded.replaceAll("-", "+").replaceAll("_", "/");
  const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
  return JSON.parse(atob(padded));
}
