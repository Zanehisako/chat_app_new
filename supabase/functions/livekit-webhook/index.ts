import { createClient } from "npm:@supabase/supabase-js@2";
import { WebhookReceiver } from "npm:livekit-server-sdk@2.17.0";
import { webhookEventTimestamp } from "./event_time.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, content-type, x-livekit-signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type LiveKitEvent = {
  id?: string;
  event?: string;
  room?: { name?: string };
  participant?: { identity?: string };
  createdAt?: bigint | number | string;
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  const apiKey = Deno.env.get("LIVEKIT_API_KEY") ?? "";
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!apiKey || !apiSecret || !supabaseUrl || !serviceRoleKey) {
    return json({ error: "Missing webhook configuration" }, 500);
  }

  const authorization = request.headers.get("Authorization") ??
    request.headers.get("x-livekit-signature") ?? "";
  const body = await request.text();
  let event: LiveKitEvent;
  try {
    event = await new WebhookReceiver(apiKey, apiSecret).receive(
      body,
      authorization,
    ) as LiveKitEvent;
  } catch (error) {
    return json(
      { error: `Invalid LiveKit webhook: ${errorMessage(error)}` },
      401,
    );
  }

  const eventName = event.event?.trim() ?? "";
  const fallbackEventId = [
    eventName,
    event.room?.name ?? "",
    event.participant?.identity ?? "",
    event.createdAt?.toString() ?? "",
  ].join(":");
  const eventId = event.id?.trim() || fallbackEventId;
  if (!eventName || !eventId) {
    return json({ error: "Webhook event is incomplete" }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
  const roomName = event.room?.name?.trim() ?? "";
  let callId: string | null = null;
  if (roomName) {
    const lookup = await supabase
      .from("group_call_sessions")
      .select("id")
      .eq("room_name", roomName)
      .maybeSingle();
    if (lookup.error) return json({ error: lookup.error.message }, 500);
    callId = lookup.data?.id?.toString() ?? null;
  }

  const inserted = await supabase.from("group_call_webhook_events").insert({
    id: eventId,
    event_name: eventName,
    call_id: callId,
  });
  if (inserted.error && inserted.error.code !== "23505") {
    return json({ error: inserted.error.message }, 500);
  }
  if (inserted.error?.code === "23505") {
    return json({ ok: true, duplicate: true });
  }
  if (!callId) return json({ ok: true, ignored: true });

  const participantIdentity = event.participant?.identity?.trim() ?? "";
  const eventAt = webhookEventTimestamp(event.createdAt);
  if (eventName === "room_finished") {
    const result = await supabase.rpc("apply_group_call_room_finished", {
      target_call_id: callId,
      reason: "livekit_room_finished",
    });
    if (result.error) {
      await removeWebhookEvent(supabase, eventId);
      return json({ error: result.error.message }, 500);
    }
  } else if (
    participantIdentity &&
    ["participant_joined", "participant_left", "participant_connection_aborted"]
      .includes(eventName)
  ) {
    const result = await supabase.rpc("apply_group_call_participant_event", {
      target_call_id: callId,
      target_user_id: participantIdentity,
      target_event: eventName,
      target_event_at: eventAt,
    });
    if (result.error) {
      await removeWebhookEvent(supabase, eventId);
      return json({ error: result.error.message }, 500);
    }
  }
  return json({ ok: true });
});

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

async function removeWebhookEvent(supabase: any, eventId: string) {
  await supabase.from("group_call_webhook_events").delete().eq("id", eventId);
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
