import { createClient } from "npm:@supabase/supabase-js@2";
import {
  fcmResponseResult,
  retryDecision,
  type SendResult,
  wnsResponseResult,
} from "./push_result.ts";

export type NotificationDelivery = {
  delivery_id: string;
  lease_id: string;
  job_id: string;
  message_id: string;
  conversation_id: string;
  recipient_id: string;
  title: string;
  body: string;
  data: Record<string, unknown>;
  attempt_count: number;
  token_id: string | null;
  provider: "fcm" | "wns" | null;
  token: string | null;
  platform: string | null;
};

// The project does not generate Supabase database types for Edge Functions.
// Keep the client dynamic here and validate every mutation response explicitly.
type DispatchClient = any;

type ProviderDependencies = {
  env: (name: string) => string | undefined;
  fetchImpl: typeof fetch;
  now: () => Date;
};

type GenericNotificationContent = {
  title: string;
  body: string;
};

export type DispatchDependencies = {
  env?: (name: string) => string | undefined;
  fetch?: typeof fetch;
  now?: () => Date;
  supabase?: DispatchClient;
};

let fcmAccessToken: { token: string; expiresAt: number } | null = null;
let wnsAccessToken: { token: string; expiresAt: number } | null = null;

export function createDispatchHandler(dependencies: DispatchDependencies = {}) {
  const env = dependencies.env ?? ((name: string) => Deno.env.get(name));
  const fetchImpl = dependencies.fetch ?? fetch;
  const now = dependencies.now ?? (() => new Date());

  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    const expectedSecret = env("NOTIFICATION_DISPATCH_SECRET")?.trim() ?? "";
    if (expectedSecret.length < 32) {
      return json({ error: "Missing notification dispatch secret" }, 500);
    }
    if (request.headers.get("x-dispatch-secret") !== expectedSecret) {
      return json({ error: "Invalid dispatch secret" }, 401);
    }

    const supabaseUrl = env("SUPABASE_URL") ?? "";
    const serviceRoleKey = env("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if ((!supabaseUrl || !serviceRoleKey) && !dependencies.supabase) {
      return json({ error: "Missing Supabase service credentials" }, 500);
    }

    const supabase = dependencies.supabase ??
      createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      });
    const requestedBatchSize = Number(
      new URL(request.url).searchParams.get("limit") ?? "25",
    );
    const batchSize = Number.isFinite(requestedBatchSize)
      ? Math.min(Math.max(Math.floor(requestedBatchSize), 1), 100)
      : 25;

    const { error: expiryError } = await supabase.rpc(
      "drop_expired_group_call_notifications",
    );
    if (expiryError) {
      return json({
        error:
          `Could not drop expired call notifications: ${expiryError.message}`,
      }, 500);
    }

    const { error: emptyJobError } = await supabase.rpc(
      "drop_empty_push_notification_jobs",
    );
    if (emptyJobError) {
      return json({
        error: `Could not finalize empty jobs: ${emptyJobError.message}`,
      }, 500);
    }

    const { data, error: claimError } = await supabase.rpc(
      "claim_push_notification_deliveries",
      { batch_size: batchSize },
    );
    if (claimError) {
      return json({ error: claimError.message }, 500);
    }

    const results: Array<Record<string, unknown>> = [];
    let persistenceFailed = false;
    for (const delivery of (data ?? []) as NotificationDelivery[]) {
      try {
        results.push(
          await processDelivery(supabase, delivery, { env, fetchImpl, now }),
        );
      } catch (error) {
        const message = errorMessage(error);
        try {
          const status = await retryDelivery(
            supabase,
            delivery,
            message,
            now(),
          );
          results.push({
            id: delivery.delivery_id,
            jobId: delivery.job_id,
            status,
            error: compact(message),
          });
        } catch (persistenceError) {
          persistenceFailed = true;
          results.push({
            id: delivery.delivery_id,
            jobId: delivery.job_id,
            status: "persistence_error",
            error: compact(errorMessage(persistenceError)),
          });
        }
      }
    }

    return json(
      { processed: results.length, results },
      persistenceFailed ? 500 : 200,
    );
  };
}

if (import.meta.main) {
  Deno.serve(createDispatchHandler());
}

async function processDelivery(
  supabase: DispatchClient,
  delivery: NotificationDelivery,
  dependencies: ProviderDependencies,
) {
  if (
    !delivery.token || !delivery.token_id || !delivery.provider ||
    !delivery.platform
  ) {
    await transitionDelivery(
      supabase,
      delivery,
      "dropped",
      "Push token is missing, expired, disabled, or belongs to another account.",
      dependencies.now(),
    );
    return {
      id: delivery.delivery_id,
      jobId: delivery.job_id,
      status: "dropped",
    };
  }

  const result = delivery.provider === "wns"
    ? await sendWns(delivery, dependencies.env, dependencies.fetchImpl)
    : await sendFcm(delivery, dependencies.env, dependencies.fetchImpl);

  if (result.invalidToken) {
    await disableToken(supabase, delivery);
  }

  if (result.ok) {
    await transitionDelivery(
      supabase,
      delivery,
      "sent",
      result.error ?? null,
      dependencies.now(),
      result.providerMessageId,
    );
    return { id: delivery.delivery_id, jobId: delivery.job_id, status: "sent" };
  }

  const error = result.error ?? "No provider accepted the notification";
  if (result.retryable) {
    const status = await retryDelivery(
      supabase,
      delivery,
      error,
      dependencies.now(),
    );
    return {
      id: delivery.delivery_id,
      jobId: delivery.job_id,
      status,
      error: compact(error),
    };
  }

  await transitionDelivery(
    supabase,
    delivery,
    "dropped",
    error,
    dependencies.now(),
  );
  return {
    id: delivery.delivery_id,
    jobId: delivery.job_id,
    status: "dropped",
    error: compact(error),
  };
}

async function disableToken(
  supabase: DispatchClient,
  delivery: NotificationDelivery,
) {
  const { data, error } = await supabase
    .from("push_device_tokens")
    .update({
      disabled_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq("id", delivery.token_id!)
    .eq("user_id", delivery.recipient_id)
    .select("id");
  requireNoError(error, "disable push token");
  if ((data ?? []).length !== 1) {
    throw new Error("Push token ownership changed while dispatching.");
  }
}

async function retryDelivery(
  supabase: DispatchClient,
  delivery: NotificationDelivery,
  error: string,
  now: Date,
) {
  const decision = retryDecision(delivery.attempt_count, now.getTime());
  await transitionDelivery(
    supabase,
    delivery,
    decision.status,
    error,
    now,
    undefined,
    decision.nextAttemptAt,
  );
  return decision.status;
}

async function transitionDelivery(
  supabase: DispatchClient,
  delivery: NotificationDelivery,
  status: "sent" | "retry" | "failed" | "dropped",
  error: string | null,
  now: Date,
  providerMessageId?: string,
  nextAttemptAt?: string,
) {
  const { data, error: updateError } = await supabase
    .from("push_notification_deliveries")
    .update({
      status,
      next_attempt_at: nextAttemptAt ?? now.toISOString(),
      lease_id: null,
      lease_expires_at: null,
      sent_at: status === "sent" ? now.toISOString() : null,
      provider_message_id: providerMessageId ?? null,
      last_error: error == null ? null : compact(error),
      updated_at: now.toISOString(),
    })
    .eq("id", delivery.delivery_id)
    .eq("lease_id", delivery.lease_id)
    .eq("status", "sending")
    .select("id");
  requireNoError(updateError, "update push delivery");
  if ((data ?? []).length !== 1) {
    throw new Error(
      "Push delivery lease was lost before its status could be saved.",
    );
  }

  const { error: aggregateError } = await supabase.rpc(
    "refresh_push_notification_job",
    { p_job_id: delivery.job_id },
  );
  requireNoError(aggregateError, "refresh push job");
}

export async function sendFcm(
  delivery: NotificationDelivery,
  env: (name: string) => string | undefined,
  fetchImpl: typeof fetch,
): Promise<SendResult> {
  const projectId = env("FCM_PROJECT_ID") ?? "";
  if (!projectId) {
    return { ok: false, retryable: true, error: "Missing FCM_PROJECT_ID" };
  }

  const accessToken = await getFcmAccessToken(env, fetchImpl);
  if (!accessToken) {
    return {
      ok: false,
      retryable: true,
      error: "Missing FCM service account credentials",
    };
  }

  const content = genericNotificationContent(delivery);
  const routingData = notificationRoutingData(delivery);
  const isGroupCall = routingData.type === "group_call";
  const message: Record<string, unknown> = {
    token: delivery.token,
    // Push providers and their OS notification stores are outside the E2EE
    // boundary. Never forward job copy or arbitrary job data: both may belong
    // to an older plaintext job or contain encrypted payload material.
    notification: content,
    data: stringifyData(routingData),
  };
  if (delivery.platform === "android") {
    message.android = {
      priority: "HIGH",
      ttl: isGroupCall ? "300s" : "2419200s",
      notification: {
        channel_id: isGroupCall ? "chat_calls" : "chat_messages",
        sound: "default",
        tag: isGroupCall
          ? routingData.call_id ?? delivery.message_id
          : delivery.message_id,
      },
    };
  } else if (delivery.platform === "ios" || delivery.platform === "macos") {
    message.apns = {
      headers: {
        "apns-priority": "10",
        "apns-collapse-id": isGroupCall
          ? routingData.call_id ?? delivery.message_id
          : delivery.message_id,
        ...(isGroupCall
          ? { "apns-expiration": String(Math.floor(Date.now() / 1000) + 300) }
          : {}),
      },
      payload: {
        aps: {
          alert: content,
          sound: "default",
        },
      },
    };
  } else if (delivery.platform === "web") {
    const webAppUrl = webAppOrigin(env("WEB_APP_URL"));
    if (!webAppUrl) {
      return {
        ok: false,
        retryable: true,
        error: "Missing or invalid WEB_APP_URL",
      };
    }
    const link = new URL("/", webAppUrl);
    link.searchParams.set("conversation", delivery.conversation_id);
    if (isGroupCall) {
      link.searchParams.set("type", "group_call");
      if (routingData.call_id != null) {
        link.searchParams.set("call_id", routingData.call_id);
      }
    }
    message.webpush = {
      headers: { TTL: isGroupCall ? "300" : "2419200", Urgency: "high" },
      notification: {
        tag: isGroupCall
          ? routingData.call_id ?? delivery.message_id
          : delivery.message_id,
        renotify: false,
      },
      fcm_options: { link: link.toString() },
    };
  }

  const response = await fetchImpl(
    `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ message }),
    },
  );
  const body = await response.text();
  if (response.ok) {
    let providerMessageId: string | undefined;
    try {
      providerMessageId = JSON.parse(body).name;
    } catch (_) {
      // A successful FCM response without a body is still accepted.
    }
    return { ok: true, providerMessageId };
  }

  return {
    ...fcmResponseResult(response.status, body),
    error: `FCM ${response.status}: ${compact(body)}`,
  };
}

export function resetPushProviderCachesForTesting() {
  fcmAccessToken = null;
  wnsAccessToken = null;
}

export async function sendWns(
  delivery: NotificationDelivery,
  env: (name: string) => string | undefined,
  fetchImpl: typeof fetch,
  retriedAfterUnauthorized = false,
): Promise<SendResult> {
  const accessToken = await getWnsAccessToken(env, fetchImpl);
  if (!accessToken) {
    return { ok: false, retryable: true, error: "Missing WNS credentials" };
  }

  const url = wnsChannelUri(delivery.token!);
  if (url == null) {
    return { ok: false, invalidToken: true, error: "Invalid WNS channel URI" };
  }

  const content = genericNotificationContent(delivery);
  const routingData = notificationRoutingData(delivery);
  const isGroupCall = routingData.type === "group_call";
  const launchParams: Record<string, string> = {
    type: routingData.type,
    conversation_id: routingData.conversation_id,
    message_id: routingData.message_id,
  };
  if (isGroupCall) {
    if (routingData.call_id != null) {
      launchParams.call_id = routingData.call_id;
    }
    if (routingData.is_video != null) {
      launchParams.is_video = routingData.is_video;
    }
  }
  const launch = new URLSearchParams(launchParams).toString();
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "text/xml",
      "X-WNS-Type": "wns/toast",
      "X-WNS-RequestForStatus": "true",
    },
    body: `<toast launch="${
      escapeXml(launch)
    }"><visual><binding template="ToastGeneric"><text>${
      escapeXml(content.title)
    }</text><text>${escapeXml(content.body)}</text></binding></visual></toast>`,
  });
  const body = await response.text();
  const notificationStatus = response.headers.get("x-wns-notificationstatus")
    ?.toLowerCase();
  const connectionStatus = response.headers.get("x-wns-deviceconnectionstatus")
    ?.toLowerCase();
  const requestId = response.headers.get("x-wns-msg-id") ?? undefined;

  if (response.status === 401 && !retriedAfterUnauthorized) {
    wnsAccessToken = null;
    return sendWns(delivery, env, fetchImpl, true);
  }
  if (connectionStatus === "disconnected") {
    return {
      ok: false,
      invalidToken: true,
      error: "WNS channel is disconnected",
    };
  }
  if (
    response.ok && notificationStatus !== "dropped" &&
    notificationStatus !== "channelthrottled"
  ) {
    return { ok: true, providerMessageId: requestId };
  }
  if (
    notificationStatus === "dropped" ||
    notificationStatus === "channelthrottled"
  ) {
    return {
      ok: false,
      retryable: true,
      error: `WNS ${notificationStatus}: ${compact(body)}`,
    };
  }
  return {
    ...wnsResponseResult(response.status),
    error: `WNS ${response.status}: ${compact(body)}`,
  };
}

async function getFcmAccessToken(
  env: (name: string) => string | undefined,
  fetchImpl: typeof fetch,
) {
  const now = Math.floor(Date.now() / 1000);
  if (fcmAccessToken && fcmAccessToken.expiresAt - 60 > now) {
    return fcmAccessToken.token;
  }

  const rawServiceAccount = env("FCM_SERVICE_ACCOUNT_JSON") ?? "";
  if (!rawServiceAccount) {
    return null;
  }
  const serviceAccount = JSON.parse(rawServiceAccount);
  const assertion = await createJwt({
    issuer: serviceAccount.client_email,
    privateKey: serviceAccount.private_key,
    audience: "https://oauth2.googleapis.com/token",
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    now,
  });
  const response = await fetchImpl("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!response.ok) {
    throw new Error(`FCM OAuth failed: ${await response.text()}`);
  }
  const payload = await response.json();
  fcmAccessToken = {
    token: payload.access_token,
    expiresAt: now + Number(payload.expires_in ?? 3600),
  };
  return fcmAccessToken.token;
}

async function getWnsAccessToken(
  env: (name: string) => string | undefined,
  fetchImpl: typeof fetch,
) {
  const now = Math.floor(Date.now() / 1000);
  if (wnsAccessToken && wnsAccessToken.expiresAt - 60 > now) {
    return wnsAccessToken.token;
  }

  const tenantId = env("WNS_TENANT_ID") ?? "";
  const clientId = env("WNS_CLIENT_ID") ?? "";
  const clientSecret = env("WNS_CLIENT_SECRET") ?? "";
  if (!tenantId || !clientId || !clientSecret) {
    return null;
  }
  const response = await fetchImpl(
    `https://login.microsoftonline.com/${tenantId}/oauth2/v2.0/token`,
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "client_credentials",
        client_id: clientId,
        client_secret: clientSecret,
        scope: "https://wns.windows.com/.default/",
      }),
    },
  );
  if (!response.ok) {
    throw new Error(`WNS OAuth failed: ${await response.text()}`);
  }
  const payload = await response.json();
  wnsAccessToken = {
    token: payload.access_token,
    expiresAt: now + Number(payload.expires_in ?? 3600),
  };
  return wnsAccessToken.token;
}

async function createJwt({
  issuer,
  privateKey,
  audience,
  scope,
  now,
}: {
  issuer: string;
  privateKey: string;
  audience: string;
  scope: string;
  now: number;
}) {
  const header = base64UrlJson({ alg: "RS256", typ: "JWT" });
  const claims = base64UrlJson({
    iss: issuer,
    scope,
    aud: audience,
    exp: now + 3600,
    iat: now,
  });
  const signingInput = `${header}.${claims}`;
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(privateKey),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64Url(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string) {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

function base64UrlJson(value: unknown) {
  return base64Url(new TextEncoder().encode(JSON.stringify(value)));
}

function base64Url(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function stringifyData(data: Record<string, unknown>) {
  const result: Record<string, string> = {};
  for (const [key, value] of Object.entries(data)) {
    const normalizedKey = fcmDataKey(key);
    if (normalizedKey == null || value === undefined) {
      continue;
    }
    result[normalizedKey] = typeof value === "string"
      ? value
      : JSON.stringify(value);
  }
  return result;
}

function genericNotificationContent(
  delivery: NotificationDelivery,
): GenericNotificationContent {
  return isGroupCallNotification(delivery)
    ? {
      title: "Incoming group call",
      body: "Open ChatApp to join it",
    }
    : {
      title: "New message",
      body: "Open ChatApp to read it",
    };
}

/**
 * Keep provider data to the identifiers needed to route a tap back into the
 * app. In particular, do not spread `delivery.data`: SQL jobs from previous
 * app versions may contain message previews, and future encrypted jobs may
 * contain ciphertext or other protocol fields.
 */
function notificationRoutingData(
  delivery: NotificationDelivery,
): Record<string, string> {
  const isGroupCall = isGroupCallNotification(delivery);
  const data: Record<string, string> = {
    type: isGroupCall ? "group_call" : "message",
    notification_job_id: delivery.job_id,
    conversation_id: delivery.conversation_id,
    message_id: delivery.message_id,
  };

  if (isGroupCall) {
    const callId = uuidValue(delivery.data.call_id);
    if (callId != null) {
      data.call_id = callId;
    }
    data.is_video = String(
      delivery.data.is_video === true ||
        delivery.data.is_video === "true",
    );
    return data;
  }

  return data;
}

function isGroupCallNotification(delivery: NotificationDelivery) {
  return delivery.data.type === "group_call";
}

function uuidValue(value: unknown) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(normalized)
    ? normalized
    : null;
}

function fcmDataKey(key: string) {
  const normalized = key.toLowerCase();
  if (
    normalized === "from" ||
    normalized.startsWith("google.") ||
    normalized.startsWith("gcm.")
  ) {
    return null;
  }
  return key;
}

function webAppOrigin(value: string | undefined) {
  if (!value) {
    return null;
  }
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url : null;
  } catch (_) {
    return null;
  }
}

export function isValidWnsChannelUri(value: string) {
  return wnsChannelUri(value) != null;
}

function wnsChannelUri(value: string) {
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase();
    const validHost = host === "notify.windows.com" ||
      host.endsWith(".notify.windows.com");
    return url.protocol === "https:" && validHost ? url : null;
  } catch (_) {
    return null;
  }
}

function requireNoError(
  error: { message: string } | null,
  operation: string,
) {
  if (error) {
    throw new Error(`${operation}: ${error.message}`);
  }
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function escapeXml(value: string) {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function compact(value: string) {
  const trimmed = value.replace(/\s+/g, " ").trim();
  return trimmed.length <= 240 ? trimmed : `${trimmed.slice(0, 240)}...`;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
