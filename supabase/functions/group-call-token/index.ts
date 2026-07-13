import { createClient } from "npm:@supabase/supabase-js@2";
import { AccessToken, RoomServiceClient } from "npm:livekit-server-sdk@2.17.0";
import { allowedPublishSources } from "./token_grants.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type CallRequest = {
  action?: string;
  conversation_id?: string;
  call_id?: string;
  is_video?: boolean;
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
  const livekitUrl = Deno.env.get("LIVEKIT_WS_URL") ?? "";
  const livekitApiKey = Deno.env.get("LIVEKIT_API_KEY") ?? "";
  const livekitApiSecret = Deno.env.get("LIVEKIT_API_SECRET") ?? "";

  if (!supabaseUrl || !anonKey) {
    return json({ error: "Missing Supabase function configuration" }, 500);
  }
  if (!livekitUrl || !livekitApiKey || !livekitApiSecret) {
    return json({ error: "LiveKit is not configured" }, 503);
  }

  let payload: CallRequest;
  try {
    payload = await request.json() as CallRequest;
  } catch (_) {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const action = payload.action?.trim();
  if (action !== "start" && action !== "join") {
    return json({ error: "action must be start or join" }, 400);
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

  const conversationId = payload.conversation_id?.trim();
  if (action === "start" && !conversationId) {
    return json({ error: "conversation_id is required" }, 400);
  }
  const callId = payload.call_id?.trim();
  if (action === "join" && !callId) {
    return json({ error: "call_id is required" }, 400);
  }

  const profile = await userClient
    .from("profiles")
    .select("display_name")
    .eq("id", user.id)
    .maybeSingle();
  const displayName = profile.data?.display_name?.toString().trim() ||
    "Someone";

  let call: Record<string, unknown>;
  if (action === "start") {
    const started = await userClient.rpc("start_group_call", {
      target_conversation_id: conversationId,
      target_is_video: payload.is_video === true,
    });
    if (started.error) {
      return json({ error: started.error.message }, 403);
    }
    call = asRecord(started.data);
    if (!call.id) {
      return json({ error: "Group call was not created" }, 500);
    }
    // Starting against an existing room is idempotent and also joins it.
    const joined = await userClient.rpc("join_group_call", {
      target_call_id: call.id,
    });
    if (joined.error) {
      return json({ error: joined.error.message }, 403);
    }
    call = asRecord(joined.data) || call;
  } else {
    const joined = await userClient.rpc("join_group_call", {
      target_call_id: callId,
    });
    if (joined.error) {
      return json({ error: joined.error.message }, 403);
    }
    call = asRecord(joined.data);
  }

  const roomName = call.room_name?.toString().trim() ?? "";
  const resolvedCallId = call.id?.toString().trim() ?? "";
  const resolvedConversationId = call.conversation_id?.toString().trim() ??
    conversationId ?? "";
  if (!roomName || !resolvedCallId || !resolvedConversationId) {
    return json({ error: "Group call metadata is incomplete" }, 500);
  }

  const roomService = new RoomServiceClient(
    apiHost(livekitUrl),
    livekitApiKey,
    livekitApiSecret,
  );
  try {
    await roomService.createRoom({
      name: roomName,
      maxParticipants: 50,
      emptyTimeout: 60,
      departureTimeout: 30,
    });
  } catch (error) {
    // A repeated start or join against the same active call is idempotent. The
    // room already exists in that case; all other control-plane failures should
    // stop token issuance instead of creating an uncapped room.
    if (
      !/already exists|already_exist|alreadyexists/i.test(errorMessage(error))
    ) {
      try {
        await userClient.rpc("fail_group_call", {
          target_call_id: resolvedCallId,
          reason: "livekit_room_create_failed",
        });
      } catch (_) {
        // Preserve the LiveKit control error even if the cleanup RPC is down.
      }
      return json({
        error: `Could not create LiveKit room: ${errorMessage(error)}`,
      }, 503);
    }
  }

  const isVideo = call.is_video === true;
  const clientLivekitUrl = websocketUrl(livekitUrl);
  const token = new AccessToken(livekitApiKey, livekitApiSecret, {
    identity: user.id,
    name: displayName,
    ttl: "60s",
  });
  token.addGrant({
    roomJoin: true,
    room: roomName,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
    canPublishSources: allowedPublishSources(isVideo),
  });

  return json({
    call_id: resolvedCallId,
    conversation_id: resolvedConversationId,
    room_name: roomName,
    server_url: clientLivekitUrl,
    participant_token: await token.toJwt(),
    is_video: isVideo,
    participant_id: user.id,
    participant_name: displayName,
    title: call.title?.toString() ?? "Group call",
    token_expires_at: new Date(Date.now() + 60_000).toISOString(),
  });
});

function asRecord(value: unknown): Record<string, unknown> {
  if (Array.isArray(value)) {
    return (value[0] ?? {}) as Record<string, unknown>;
  }
  return (value ?? {}) as Record<string, unknown>;
}

function websocketUrl(value: string) {
  return value.replace(/^https:/, "wss:").replace(/^http:/, "ws:").replace(
    /\/$/,
    "",
  );
}

function apiHost(value: string) {
  return value.replace(/^wss:/, "https:").replace(/^ws:/, "http:").replace(
    /\/$/,
    "",
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
