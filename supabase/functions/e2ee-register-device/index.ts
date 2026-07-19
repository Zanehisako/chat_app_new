import { createClient } from "npm:@supabase/supabase-js@2";
import {
  isUnpaddedBase64Url,
  verifyDeviceCertificate,
} from "./device_certificate.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type DeviceRegistration = {
  deviceId: string;
  encryptionPublicKey: string;
  signingPublicKey: string;
  certificate: string;
  label: string | null;
  protocolVersion: number;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const authorization = request.headers.get("authorization")?.trim() ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Missing bearer token" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: "Missing Supabase function configuration" }, 500);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch (_) {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const registration = parseRegistration(body);
  if (registration == null) {
    return json({ error: "Invalid encrypted device registration" }, 400);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) {
    return json({ error: "Invalid authentication" }, 401);
  }
  const user = userData.user;

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const account = await serviceClient
    .from("e2ee_accounts")
    .select("signing_public_key")
    .eq("user_id", user.id)
    .maybeSingle();
  if (account.error) {
    return json({ error: "Could not load encrypted account identity" }, 500);
  }
  const accountSigningPublicKey = account.data?.signing_public_key?.trim() ?? "";
  if (!isUnpaddedBase64Url(accountSigningPublicKey, 40, 512)) {
    return json({ error: "Register the encrypted account before this device" }, 409);
  }

  const certificateValid = await verifyDeviceCertificate({
    userId: user.id,
    deviceId: registration.deviceId,
    encryptionPublicKey: registration.encryptionPublicKey,
    signingPublicKey: registration.signingPublicKey,
    accountSigningPublicKey,
    certificate: registration.certificate,
  });
  if (!certificateValid) {
    return json({ error: "The encrypted device certificate is invalid" }, 400);
  }

  const stored = await serviceClient.rpc("register_verified_e2ee_device", {
    p_user_id: user.id,
    p_device_id: registration.deviceId,
    p_encryption_public_key: registration.encryptionPublicKey,
    p_signing_public_key: registration.signingPublicKey,
    p_certificate: registration.certificate,
    p_label: registration.label,
    p_protocol_version: registration.protocolVersion,
  });
  if (stored.error) {
    return json({ error: stored.error.message }, 409);
  }
  return json({ device_id: registration.deviceId });
});

function parseRegistration(value: unknown): DeviceRegistration | null {
  if (value == null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const data = value as Record<string, unknown>;
  const deviceId = data.device_id;
  const encryptionPublicKey = data.encryption_public_key;
  const signingPublicKey = data.signing_public_key;
  const certificate = data.certificate;
  const label = data.label;
  const protocolVersion = data.protocol_version;
  if (typeof deviceId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(deviceId) ||
    !isUnpaddedBase64Url(encryptionPublicKey, 40, 512) ||
    !isUnpaddedBase64Url(signingPublicKey, 40, 512) ||
    !isUnpaddedBase64Url(certificate, 64, 1024) ||
    (label != null && (typeof label !== "string" || label.length > 120)) ||
    protocolVersion !== 1) {
    return null;
  }
  return {
    deviceId,
    encryptionPublicKey,
    signingPublicKey,
    certificate,
    label: typeof label === "string" ? label.trim() || null : null,
    protocolVersion,
  };
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
