import { createClient } from "npm:@supabase/supabase-js@2";
import { RoomServiceClient } from "npm:livekit-server-sdk@2.17.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-dispatch-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }
  const expectedSecret = Deno.env.get("GROUP_CALL_CONTROL_SECRET")?.trim() ??
    "";
  if (
    expectedSecret.length < 32 ||
    request.headers.get("x-dispatch-secret") !== expectedSecret
  ) {
    return json({ error: "Invalid control secret" }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const apiKey = Deno.env.get("LIVEKIT_API_KEY") ?? "";
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
  const livekitUrl = Deno.env.get("LIVEKIT_WS_URL") ?? "";
  if (!supabaseUrl || !serviceRoleKey || !apiKey || !apiSecret || !livekitUrl) {
    return json({ error: "Missing control configuration" }, 500);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
  const claimed = await supabase.rpc("claim_group_call_control_jobs", {
    batch_size: 25,
  });
  if (claimed.error) return json({ error: claimed.error.message }, 500);
  const service = new RoomServiceClient(apiHost(livekitUrl), apiKey, apiSecret);
  let processed = 0;
  for (const job of (claimed.data ?? []) as Array<Record<string, unknown>>) {
    let succeeded = false;
    let failure = "";
    try {
      const session = await supabase
        .from("group_call_sessions")
        .select("room_name, status")
        .eq("id", job.call_id)
        .maybeSingle();
      if (session.error) throw new Error(session.error.message);
      const roomName = session.data?.room_name?.toString() ?? "";
      if (!roomName) throw new Error("Group call room is missing");
      if (session.data?.status === "active") {
        await service.removeParticipant(
          roomName,
          job.user_id?.toString() ?? "",
        );
      }
      succeeded = true;
    } catch (error) {
      failure = errorMessage(error);
    }
    const result = await supabase.rpc("finish_group_call_control_job", {
      target_job_id: job.id,
      succeeded,
      failure_reason: failure || null,
    });
    if (result.error) return json({ error: result.error.message }, 500);
    processed += 1;
  }
  return json({ processed });
});

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
