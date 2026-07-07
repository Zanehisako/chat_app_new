const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const authorization = request.headers.get("authorization") ?? "";
  if (!authorization.toLowerCase().startsWith("bearer ")) {
    return json({ error: "Missing bearer token" }, 401);
  }

  const secret = Deno.env.get("TURN_SECRET") ?? "";
  const urls = (Deno.env.get("TURN_URLS") ?? "")
    .split(",")
    .map((url) => url.trim())
    .filter(Boolean);
  const ttlSeconds = Number(Deno.env.get("TURN_TTL_SECONDS") ?? "3600");

  if (!secret || urls.length === 0) {
    return json({ error: "TURN_SECRET and TURN_URLS are required" }, 500);
  }

  const expires = Math.floor(Date.now() / 1000) + ttlSeconds;
  const username = `${expires}:chat_app`;
  const credential = await hmacSha1Base64(secret, username);

  return json({
    ttlSeconds,
    iceServers: [
      {
        urls,
        username,
        credential,
      },
    ],
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });
}

async function hmacSha1Base64(secret: string, message: string) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(message),
  );
  return btoa(String.fromCharCode(...new Uint8Array(signature)));
}
