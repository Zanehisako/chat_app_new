import {
  type NotificationDelivery,
  resetPushProviderCachesForTesting,
  sendFcm,
  sendWns,
} from "./index.ts";

Deno.test("FCM sends generic Android copy and routing-only data", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const requests: string[] = [];
  const pushDelivery = delivery("android");
  const result = await sendFcm(
    pushDelivery,
    envFor(serviceAccount),
    (input, init) => {
      const url = input.toString();
      requests.push(url);
      if (url === "https://oauth2.googleapis.com/token") {
        return Promise.resolve(Response.json({
          access_token: "access-token",
          expires_in: 3600,
        }));
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
      assertGenericMessagePayload(payload, pushDelivery);
      return Promise.resolve(
        Response.json({ name: "projects/chat-app-92f45/messages/1" }),
      );
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
  const pushDelivery = delivery("web");
  const result = await sendFcm(
    pushDelivery,
    envFor(serviceAccount),
    (input, init) => {
      if (input.toString() === "https://oauth2.googleapis.com/token") {
        return Promise.resolve(Response.json({
          access_token: "access-token",
          expires_in: 3600,
        }));
      }
      const payload = JSON.parse(String(init?.body));
      if (
        payload.message.webpush.headers.TTL !== "2419200" ||
        payload.message.webpush.headers.Urgency !== "high" ||
        !payload.message.webpush.fcm_options.link.includes(
          pushDelivery.conversation_id,
        )
      ) {
        throw new Error(
          `Web offline delivery settings are invalid: ${
            JSON.stringify(payload)
          }`,
        );
      }
      assertGenericMessagePayload(payload, pushDelivery);
      return Promise.resolve(
        Response.json({ name: "projects/chat-app-92f45/messages/web-1" }),
      );
    },
  );

  if (!result.ok) {
    throw new Error(`Unexpected web FCM result: ${JSON.stringify(result)}`);
  }
});

Deno.test("FCM uses generic APNs content and routing-only data", async () => {
  resetPushProviderCachesForTesting();
  const serviceAccount = await testServiceAccount();
  const pushDelivery = delivery("ios");
  const result = await sendFcm(
    pushDelivery,
    envFor(serviceAccount),
    (input, init) => {
      if (input.toString() === "https://oauth2.googleapis.com/token") {
        return Promise.resolve(Response.json({
          access_token: "access-token",
          expires_in: 3600,
        }));
      }
      const payload = JSON.parse(String(init?.body));
      const alert = payload.message.apns?.payload?.aps?.alert;
      if (
        alert?.title !== "New message" ||
        alert?.body !== "Open ChatApp to read it"
      ) {
        throw new Error(`APNs alert was not generic: ${JSON.stringify(alert)}`);
      }
      assertGenericMessagePayload(payload, pushDelivery);
      return Promise.resolve(
        Response.json({ name: "projects/chat-app-92f45/messages/ios-1" }),
      );
    },
  );

  if (!result.ok) {
    throw new Error(`Unexpected iOS FCM result: ${JSON.stringify(result)}`);
  }
});

Deno.test("WNS sends generic group-call copy and only launch routing identifiers", async () => {
  resetPushProviderCachesForTesting();
  const pushDelivery = {
    ...delivery("windows"),
    provider: "wns" as const,
    token: "https://example.notify.windows.com/channel",
    data: {
      type: "group_call",
      call_id: "10000000-0000-4000-8000-000000000008",
      is_video: true,
      ciphertext: "private-ciphertext-should-never-leave",
    },
  };
  const result = await sendWns(
    pushDelivery,
    wnsEnv,
    (input, init) => {
      if (input.toString().startsWith("https://login.microsoftonline.com/")) {
        return Promise.resolve(Response.json({
          access_token: "wns-access-token",
          expires_in: 3600,
        }));
      }
      const toast = String(init?.body);
      if (
        !toast.includes("Incoming group call") ||
        !toast.includes("Open ChatApp to join it") ||
        !toast.includes(`conversation_id=${pushDelivery.conversation_id}`) ||
        !toast.includes(`message_id=${pushDelivery.message_id}`) ||
        !toast.includes("type=group_call") ||
        !toast.includes(`call_id=${pushDelivery.data.call_id}`) ||
        !toast.includes("is_video=true")
      ) {
        throw new Error(`WNS routing toast is incomplete: ${toast}`);
      }
      assertNoPrivateContent(toast);
      return Promise.resolve(
        new Response("", {
          status: 200,
          headers: {
            "x-wns-notificationstatus": "received",
            "x-wns-deviceconnectionstatus": "connected",
            "x-wns-msg-id": "wns-1",
          },
        }),
      );
    },
  );

  if (!result.ok || result.providerMessageId !== "wns-1") {
    throw new Error(`Unexpected WNS result: ${JSON.stringify(result)}`);
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
    (input) => {
      if (input.toString() === "https://oauth2.googleapis.com/token") {
        return Promise.resolve(Response.json({
          access_token: "access-token",
          expires_in: 3600,
        }));
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

function delivery(platform: string): NotificationDelivery {
  return {
    delivery_id: "10000000-0000-0000-0000-000000000001",
    lease_id: "10000000-0000-0000-0000-000000000002",
    job_id: "10000000-0000-0000-0000-000000000003",
    message_id: "10000000-0000-0000-0000-000000000004",
    conversation_id: "10000000-0000-0000-0000-000000000005",
    recipient_id: "10000000-0000-0000-0000-000000000006",
    title: "private-title-should-never-leave",
    body: "private-body-should-never-leave",
    data: {
      type: "message",
      message_type: "text",
      from: "reserved",
      "google.test": "reserved",
      metadata: { source: "test" },
      title: "private-data-title-should-never-leave",
      body: "private-data-body-should-never-leave",
      plaintext: "private-plaintext-should-never-leave",
      ciphertext: "private-ciphertext-should-never-leave",
    },
    attempt_count: 1,
    token_id: "10000000-0000-0000-0000-000000000007",
    provider: "fcm",
    token: "device-token",
    platform,
  };
}

const privateValues = [
  "private-title-should-never-leave",
  "private-body-should-never-leave",
  "private-data-title-should-never-leave",
  "private-data-body-should-never-leave",
  "private-plaintext-should-never-leave",
  "private-ciphertext-should-never-leave",
  "reserved",
  "source",
];

function assertGenericMessagePayload(
  payload: Record<string, unknown>,
  pushDelivery: NotificationDelivery,
) {
  const message = recordValue(payload.message, "FCM message");
  const notification = recordValue(
    message.notification,
    "FCM notification",
  );
  if (
    notification.title !== "New message" ||
    notification.body !== "Open ChatApp to read it"
  ) {
    throw new Error(
      `FCM notification copy was not generic: ${JSON.stringify(notification)}`,
    );
  }
  const expectedData = {
    type: "message",
    notification_job_id: pushDelivery.job_id,
    conversation_id: pushDelivery.conversation_id,
    message_id: pushDelivery.message_id,
  };
  const data = recordValue(message.data, "FCM data");
  if (JSON.stringify(data) !== JSON.stringify(expectedData)) {
    throw new Error(
      `FCM data leaked or lost fields: ${JSON.stringify(data)}`,
    );
  }
  assertNoPrivateContent(JSON.stringify(payload));
}

function recordValue(value: unknown, label: string): Record<string, unknown> {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} was not an object.`);
  }
  return value as Record<string, unknown>;
}

function assertNoPrivateContent(payload: string) {
  const leaked = privateValues.find((value) => payload.includes(value));
  if (leaked != null) {
    throw new Error(`Private notification value escaped: ${leaked}`);
  }
}

function envFor(serviceAccount: string) {
  return (name: string) => {
    if (name === "FCM_PROJECT_ID") return "chat-app-92f45";
    if (name === "FCM_SERVICE_ACCOUNT_JSON") return serviceAccount;
    if (name === "WEB_APP_URL") return "https://chat-app-92f45.web.app";
    return undefined;
  };
}

function wnsEnv(name: string) {
  if (name === "WNS_TENANT_ID") return "tenant-id";
  if (name === "WNS_CLIENT_ID") return "client-id";
  if (name === "WNS_CLIENT_SECRET") return "client-secret";
  return undefined;
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
