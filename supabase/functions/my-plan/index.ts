import { createClient } from "jsr:@supabase/supabase-js@2";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const RANK: Record<string, number> = { artist: 1, plus: 2, pro: 3 };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer /i, "");
  const { data, error } = token ? await admin.auth.getUser(token) : { data: null, error: true };
  if (error || !data || !data.user) return json({ error: "Sign in." }, 401);
  const key = Deno.env.get("RC_SECRET_KEY");
  if (!key) return json({ error: "not_configured" }, 503);
  // RevenueCat knows each subscriber by their Supabase user id (the app logs in with it)
  const r = await fetch("https://api.revenuecat.com/v1/subscribers/" + encodeURIComponent(data.user.id), { headers: { Authorization: "Bearer " + key } });
  if (!r.ok) return json({ error: "lookup_failed" }, 502);
  const sub = (await r.json()).subscriber || {};
  const now = Date.now();
  let best: string | null = null, trial = false;
  for (const [name, e] of Object.entries<any>(sub.entitlements || {})) {
    if (!RANK[name]) continue;
    const active = !e.expires_date || Date.parse(e.expires_date) > now;
    if (active && (!best || RANK[name] > RANK[best])) { best = name; trial = (sub.subscriptions?.[e.product_identifier]?.period_type || "") === "trial"; }
  }
  return json({ tier: best, trial });
});
