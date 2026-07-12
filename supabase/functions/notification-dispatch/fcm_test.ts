import {
  type NotificationDelivery,
  resetPushProviderCachesForTesting,
  sendFcm,
} from "./index.ts";

Deno.test("FCM obtains OAuth token and sends an Android notification", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const requests: string[] = [];
  const result = await sendFcm(
    delivery("android"),
    envFor(serviceAccount),
    async (input, init) => {
      const url = input.toString();
      requests.push(url);
      if (url === "https://oauth2.googleapis.com/token") {
        return Response.json({
          access_token: "access-token",
          expires_in: 3600,
        });
      }
      if (
        init?.headers == null ||
        new Headers(init.headers).get("Authorization") !== "Bearer access-token"
      ) {
        throw new Error("FCM request did not use the OAuth access token.");
      }
      const payload = JSON.parse(String(init.body));
      if (payload.message.android.notification.channel_id !== "chat_messages") {
        throw new Error("Android notification channel was not included.");
      }
      if (payload.message.android.ttl !== "2419200s") {
        throw new Error("Android offline delivery lifetime was not included.");
      }
      if (
        payload.message.data.message_type !== undefined ||
        payload.message.data.from !== undefined ||
        payload.message.data["google.test"] !== undefined ||
        payload.message.data.chat_message_type !== "text" ||
        payload.message.data.metadata !== '{"source":"test"}'
      ) {
        throw new Error(
          `FCM data keys were not sanitized: ${
            JSON.stringify(payload.message.data)
          }`,
        );
      }
      return Response.json({ name: "projects/chat-app-92f45/messages/1" });
    },
  );

  if (
    !result.ok || result.providerMessageId !==
      "projects/chat-app-92f45/messages/1" ||
    requests.length !== 2
  ) {
    throw new Error(`Unexpected Android FCM result: ${JSON.stringify(result)}`);
  }
});

Deno.test("FCM sends web notifications with an offline lifetime", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const result = await sendFcm(
    delivery("web"),
    envFor(serviceAccount),
    async (input, init) => {
      if (input.toString() === "https://oauth2.googleapis.com/token") {
        return Response.json({
          access_token: "access-token",
          expires_in: 3600,
        });
      }
      const payload = JSON.parse(String(init?.body));
      if (
        payload.message.webpush.headers.TTL !== "2419200" ||
        payload.message.webpush.headers.Urgency !== "high" ||
        !payload.message.webpush.fcm_options.link.includes(
          delivery("web").conversation_id,
        )
      ) {
        throw new Error(
          `Web offline delivery settings are invalid: ${
            JSON.stringify(payload)
          }`,
        );
      }
      return Response.json({ name: "projects/chat-app-92f45/messages/web-1" });
    },
  );

  if (!result.ok) {
    throw new Error(`Unexpected web FCM result: ${JSON.stringify(result)}`);
  }
});

Deno.test("FCM marks invalid tokens as terminal", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const result = await sendFcm(
    delivery("android"),
    envFor(serviceAccount),
    tokenThen(
      new Response(
        JSON.stringify({ error: { status: "UNREGISTERED" } }),
        { status: 404 },
      ),
    ),
  );

  if (result.ok || !result.invalidToken || result.retryable) {
    throw new Error(
      `Invalid FCM token was not terminal: ${JSON.stringify(result)}`,
    );
  }
});

Deno.test("FCM retries transient provider failures", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const result = await sendFcm(
    delivery("android"),
    envFor(serviceAccount),
    tokenThen(new Response("temporarily unavailable", { status: 503 })),
  );

  if (result.ok || !result.retryable || result.invalidToken) {
    throw new Error(
      `Transient FCM error did not retry: ${JSON.stringify(result)}`,
    );
  }
});

Deno.test("web delivery fails before send without a valid HTTPS app URL", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const result = await sendFcm(
    delivery("web"),
    (name) =>
      name === "WEB_APP_URL"
        ? "http://insecure.example.test"
        : envFor(serviceAccount)(name),
    async (input) => {
      if (input.toString() === "https://oauth2.googleapis.com/token") {
        return Response.json({
          access_token: "access-token",
          expires_in: 3600,
        });
      }
      throw new Error("FCM should not be called for an invalid web origin.");
    },
  );

  if (
    result.ok || !result.retryable ||
    result.error !== "Missing or invalid WEB_APP_URL"
  ) {
    throw new Error(`Invalid web URL was accepted: ${JSON.stringify(result)}`);
  }
});

Deno.test("missing FCM credentials return a retryable failure", async () => {
  resetPushProviderCachesForTesting();
  const result = await sendFcm(
    delivery("android"),
    (name) => name === "FCM_PROJECT_ID" ? "chat-app-92f45" : undefined,
    () => Promise.reject(new Error("fetch should not run")),
  );

  if (
    result.ok || !result.retryable ||
    result.error !== "Missing FCM service account credentials"
  ) {
    throw new Error(
      `Missing credentials were not rejected: ${JSON.stringify(result)}`,
    );
  }
});

function delivery(platform: "android" | "web"): NotificationDelivery {
  return {
    delivery_id: "10000000-0000-0000-0000-000000000001",
    lease_id: "10000000-0000-0000-0000-000000000002",
    job_id: "10000000-0000-0000-0000-000000000003",
    message_id: "10000000-0000-0000-0000-000000000004",
    conversation_id: "10000000-0000-0000-0000-000000000005",
    recipient_id: "10000000-0000-0000-0000-000000000006",
    title: "Sender",
    body: "Hello",
    data: {
      type: "message",
      message_type: "text",
      from: "reserved",
      "google.test": "reserved",
      metadata: { source: "test" },
    },
    attempt_count: 1,
    token_id: "10000000-0000-0000-0000-000000000007",
    provider: "fcm",
    token: "device-token",
    platform,
  };
}

function envFor(serviceAccount: string) {
  return (name: string) => {
    if (name === "FCM_PROJECT_ID") return "chat-app-92f45";
    if (name === "FCM_SERVICE_ACCOUNT_JSON") return serviceAccount;
    if (name === "WEB_APP_URL") return "https://chat-app-92f45.web.app";
    return undefined;
  };
}

function tokenThen(fcmResponse: Response): typeof fetch {
  return (input) => {
    if (input.toString() === "https://oauth2.googleapis.com/token") {
      return Promise.resolve(
        Response.json({ access_token: "access-token", expires_in: 3600 }),
      );
    }
    return Promise.resolve(fcmResponse);
  };
}

async function testServiceAccount() {
  const keys = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", keys.privateKey),
  );
  const base64 = btoa(String.fromCharCode(...pkcs8));
  const lines = base64.match(/.{1,64}/g)?.join("\n") ?? base64;
  return JSON.stringify({
    client_email: "push-test@chat-app-92f45.iam.gserviceaccount.com",
    private_key:
      `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`,
  });
}
