import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const rooms = [
  "Garden", "Kitchen", "Hall", "Backstage", "Band Stand", "Stage",
  "Sanctuary", "Forum", "Hallway", "WC", "Office (west)", "Vestry",
  "Lounge", "Storage", "Youth Room", "Office (east)", "Side room",
];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceRoleKey) {
    console.error("Missing required Supabase function secrets.");
    return json({ error: "Server configuration is incomplete." }, 500);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return json({ error: "You must be signed in as an administrator." }, 401);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const token = authHeader.slice("Bearer ".length);
  const { data: authData, error: authError } = await adminClient.auth.getUser(token);
  if (authError || !authData.user) {
    return json({ error: "Your session is invalid or has expired. Please sign in again." }, 401);
  }

  const { data: callerProfile, error: profileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", authData.user.id)
    .maybeSingle();

  if (profileError) {
    console.error("Could not verify administrator role:", profileError);
    return json({ error: "Could not verify administrator permissions." }, 500);
  }
  if (callerProfile?.role !== "admin") {
    return json({ error: "Only administrators can create player accounts." }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "Request body must be valid JSON." }, 400);
  }

  const username = typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const startingRoom = typeof body.starting_room === "string" ? body.starting_room : "";
  const ability = typeof body.ability === "string" ? body.ability.trim() : "";

  if (!/^[a-z0-9_-]{3,24}$/.test(username)) {
    return json({ error: "Username must be 3–24 characters and use only letters, numbers, underscores or hyphens." }, 400);
  }
  if (password.length < 8 || password.length > 128) {
    return json({ error: "Password must be between 8 and 128 characters." }, 400);
  }
  if (!rooms.includes(startingRoom)) {
    return json({ error: "Choose a valid starting room." }, 400);
  }
  if (ability.length > 200) {
    return json({ error: "Custom ability must be 200 characters or fewer." }, 400);
  }

  const { data: existing, error: lookupError } = await adminClient
    .from("profiles")
    .select("id")
    .eq("username", username)
    .maybeSingle();

  if (lookupError) {
    console.error("Username lookup failed:", lookupError);
    return json({ error: "Could not check whether that username is available." }, 500);
  }
  if (existing) return json({ error: "That username is already taken." }, 409);

  const email = `${username}@players.urcescape.invalid`;
  const { data: created, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      username,
      starting_room: startingRoom,
      ability: ability || null,
    },
  });

  if (createError) {
    console.error("Player account creation failed:", createError);
    return json({ error: createError.message || "Could not create the player account." }, 400);
  }

  return json({
    success: true,
    username,
    user_id: created.user.id,
    starting_room: startingRoom,
  }, 201);
});
