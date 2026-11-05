import { createClient } from "jsr:@supabase/supabase-js@2";

/* Import a hook: a few frames from the first seconds of a short video (the person's own screen recording or screenshots)
   come in; a filming-technique card plus a diagram recipe goes out. Secrets: ANTHROPIC_API_KEY, RC_SECRET_KEY (already set for my-plan).
   Optional: HOOK_MODEL. Table: public.hook_imports (usage log, service role only). */
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });
const RANK: Record<string, number> = { artist: 1, plus: 2, pro: 3 };
/* day = rolling 24 hours, month = rolling 30 days */
const LIMITS: Record<string, { day: number | null; month: number }> = { artist: { day: null, month: 7 }, plus: { day: 2, month: 30 }, pro: { day: 2, month: 30 } };
const MODEL = Deno.env.get("HOOK_MODEL") || "claude-sonnet-5-5";
const DAY = 86400_000, MONTH = 30 * DAY, IN_FLIGHT = 3 * 60_000;
const MAX_FRAMES = 6, MAX_FRAME_CHARS = 700_000, MAX_TOTAL_CHARS = 3_500_000;

const SIZES = ["CU", "MCU", "ECU", "MS", "FS", "LS", "MLS", "ELS", "W", "CU (OTS)", "MCU (OTS)", "ECU (OTS)", "MS (OTS)"];
const ANGLES = ["Eyelevel", "Low Angle", "High Angle", "Extreme Low", "Extreme High", "Dutch Tilt", "POV"];
const MOVES = ["Static", "Pan", "Tilt", "Pedestal", "Dolly", "Truck", "Arc", "Steadicam", "Handheld", "Crane / Boom", "Tracking Shot", "Zoom", "Rack Focus", "Push In", "Pull Out"];
const CATS = ["visual", "motion", "words", "music"];
const KINDS = ["person", "bar", "ring", "object", "dot", "text", "wave", "line", "cover", "flash"];
const ANIMS = ["none", "enter", "rise", "bob", "wipe", "pulse", "react", "flash", "pull", "strike", "pop", "fadein", "fadeout", "spinrev"];
const TONES = ["normal", "accent", "dim"];

async function userFrom(req: Request) {
  const t = (req.headers.get("Authorization") || "").replace(/^Bearer /i, "");
  if (!t) return null;
  const { data, error } = await admin.auth.getUser(t);
  return error ? null : data.user;
}
/* the plan comes from RevenueCat (the app logs in with the Supabase user id), same as my-plan */
async function tierOf(uid: string): Promise<{ tier: string | null; err?: number }> {
  const key = Deno.env.get("RC_SECRET_KEY");
  if (!key) return { tier: null, err: 503 };
  const r = await fetch("https://api.revenuecat.com/v1/subscribers/" + encodeURIComponent(uid), { headers: { Authorization: "Bearer " + key } });
  if (!r.ok) return { tier: null, err: 502 };
  const sub = (await r.json()).subscriber || {};
  const now = Date.now();
  let best: string | null = null;
  for (const [name, e] of Object.entries<any>(sub.entitlements || {})) {
    if (!RANK[name]) continue;
    const active = !e.expires_date || Date.parse(e.expires_date) > now;
    if (active && (!best || RANK[name] > RANK[best])) best = name;
  }
  return { tier: best };
}
async function usageOf(uid: string, tier: string) {
  const lim = LIMITS[tier], now = Date.now();
  const { data } = await admin.from("hook_imports").select("created_at,done").eq("user_id", uid).gt("created_at", new Date(now - MONTH).toISOString()).order("created_at", { ascending: true });
  // only finished imports count; one still running counts for a few minutes (so quick double taps can't skip the limit), then drops off if it never finished
  const times = (data || []).filter((r: any) => r.done || now - new Date(r.created_at).getTime() < IN_FLIGHT).map((r: any) => new Date(r.created_at).getTime());
  const dayTimes = times.filter((t) => t > now - DAY);
  const month_used = times.length, day_used = dayTimes.length;
  const dayFull = lim.day != null && day_used >= lim.day, monthFull = month_used >= lim.month;
  let next_at: string | null = null;
  if (monthFull) next_at = new Date(times[0] + MONTH).toISOString();
  else if (dayFull) next_at = new Date(dayTimes[0] + DAY).toISOString();
  return { tier, day_limit: lim.day, day_used, month_limit: lim.month, month_used, blocked: dayFull || monthFull, next_at };
}

const str = (v: unknown, n: number) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, n) : "");
const pick = (v: unknown, list: string[], d = "") => (typeof v === "string" && list.includes(v) ? v : d);
const num = (v: unknown, lo: number, hi: number, d: number) => (typeof v === "number" && isFinite(v) ? Math.max(lo, Math.min(hi, v)) : d);

/* the model's answer is only ever used through these whitelists: no markup, no free-form drawing */
function cleanDiagram(raw: unknown) {
  if (!Array.isArray(raw)) return [];
  return raw.slice(0, 8).map((it: any) => {
    const kind = pick(it?.kind, KINDS); if (!kind) return null;
    const o: Record<string, unknown> = { kind, anim: pick(it?.anim, ANIMS, "none"), tone: pick(it?.tone, TONES, "normal") };
    o.x = num(it?.x, 58, 102, 80); o.y = num(it?.y, 14, 86, 50);
    if (kind === "bar") o.w = num(it?.w, 8, 44, 30);
    if (kind === "ring" || kind === "dot") o.r = num(it?.r, 4, 32, 14);
    if (kind === "object") { o.w = num(it?.w, 8, 44, 24); o.h = num(it?.h, 6, 44, 18); }
    if (kind === "text") o.text = str(it?.text, 3) || "!";
    return o;
  }).filter(Boolean);
}
function cleanHook(h: any) {
  const how = (Array.isArray(h?.how) ? h.how : []).map((x: unknown) => str(x, 140)).filter(Boolean).slice(0, 4);
  const name = str(h?.name, 40), gist = str(h?.gist, 160);
  if (!name || !gist || how.length < 2) return null;
  return {
    name, cat: pick(h?.cat, CATS, "visual"), gist, how, tip: str(h?.tip, 140),
    size: pick(h?.size, SIZES), angle: pick(h?.angle, ANGLES), movement: pick(h?.movement, MOVES),
    diagram: cleanDiagram(h?.diagram),
  };
}

const SYSTEM = `You turn a few frames from the first seconds of a short social video into a reusable FILMING TECHNIQUE card for a videographer. The frames come from the person's own screen recording or screenshots, in time order (earliest first).

Rules:
- Find the single most eye-catching device in the opening (the hook): a camera move, an odd angle, a lens effect, a prop, an edit trick, on-screen text treatment, a beat-synced cut, and so on.
- Describe the TECHNIQUE in your own original words so anyone could do it with their own subject. Do not describe the specific video. Never include names of people, accounts, brands, songs or lyrics, and never copy on-screen text or captions; if text is the technique, describe it generically (for example "one big number").
- Ignore app interface chrome from the screen recording (buttons, usernames, like counts).
- If the frames show no discernible technique (blank, not video, unreadable, or just a person talking with nothing special), call the tool with usable=false and one short reason.
- Name: 2-4 plain words. Gist: one sentence. How: 3 short steps, each starting with a verb. Tip: one short sentence.
- size, angle, movement: fill only if clearly part of the technique, using the allowed values, else leave empty.

DIAGRAM: draw a tiny looping schematic (about 3 seconds) of the technique on a phone-shaped frame (the phone outline is drawn for you). Coordinates: x from 58 to 102, y from 14 to 86, center is (80, 50). Use 2 to 7 items. Kinds: person (a simple figure at x,y), bar (a line of text at x,y with width w), ring (a circle outline, radius r), object (a rounded box at x,y, size w,h), dot (a filled circle, radius r), text (1 to 3 big characters like a number), wave (an audio waveform in the middle), line (a dashed vertical divider), cover (a panel over the whole screen), flash (a white flash over the whole screen). tone: normal, accent (highlight color) or dim. Each item gets an anim: none, enter (slides in from the left), rise (comes up from below), bob (bounces), wipe (slides away), pulse (breathes), react (small jump), flash (blinks), pull (zooms from close to normal), strike (a line draws across), pop (pops in), fadein, fadeout, spinrev (spins backward).
Examples:
- Walking into an empty frame: [{"kind":"person","x":80,"y":48,"anim":"enter"}]
- Cover the lens then reveal: [{"kind":"person","x":80,"y":46},{"kind":"cover","anim":"wipe"}]
- One big number on screen: [{"kind":"text","x":80,"y":64,"text":"7","anim":"pop"}]
- Colorful prop beside the subject: [{"kind":"person","x":90,"y":48},{"kind":"dot","x":68,"y":62,"r":9,"tone":"accent","anim":"bob"}]
- Two takes side by side: [{"kind":"line","x":80,"y":50},{"kind":"person","x":67,"y":46,"anim":"pulse"},{"kind":"person","x":93,"y":46,"anim":"react"}]`;

const TOOL = {
  name: "save_hook",
  description: "Save the filming technique card and its diagram.",
  input_schema: {
    type: "object",
    properties: {
      usable: { type: "boolean" },
      reason: { type: "string", description: "Only when usable is false: one short sentence." },
      name: { type: "string" }, cat: { type: "string", enum: CATS }, gist: { type: "string" },
      how: { type: "array", items: { type: "string" }, minItems: 3, maxItems: 4 },
      tip: { type: "string" },
      size: { type: "string", enum: ["", ...SIZES] }, angle: { type: "string", enum: ["", ...ANGLES] }, movement: { type: "string", enum: ["", ...MOVES] },
      diagram: {
        type: "array", maxItems: 8,
        items: {
          type: "object",
          properties: {
            kind: { type: "string", enum: KINDS }, x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" }, r: { type: "number" },
            tone: { type: "string", enum: TONES }, anim: { type: "string", enum: ANIMS }, text: { type: "string" },
          },
          required: ["kind"],
        },
      },
    },
    required: ["usable"],
  },
};

function parseFrame(s: unknown) {
  const m = typeof s === "string" ? /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=]+)$/.exec(s) : null;
  return m ? { type: "image", source: { type: "base64", media_type: m[1], data: m[2] } } : null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let b: any; try { b = await req.json(); } catch { return json({ error: "Bad request" }, 400); }
  try {
    const u = await userFrom(req); if (!u) return json({ error: "Sign in to import a hook." }, 401);
    const { tier, err } = await tierOf(u.id);
    if (err) return json({ error: err === 503 ? "not_configured" : "Couldn't check your plan. Try again." }, err);
    if (!tier) return json({ error: "Importing hooks comes with a creatrr plan." }, 403);

    if (b.action === "usage") return json({ usage: await usageOf(u.id, tier) });
    if (b.action !== "import") return json({ error: "Unknown action" }, 400);

    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ error: "not_configured" }, 503);
    const frames = (Array.isArray(b.frames) ? b.frames : []).slice(0, MAX_FRAMES);
    if (!frames.length || frames.some((f: unknown) => typeof f !== "string" || f.length > MAX_FRAME_CHARS) || frames.reduce((n: number, f: string) => n + f.length, 0) > MAX_TOTAL_CHARS) return json({ error: "Those images are too big. Try fewer or shorter ones." }, 413);
    const blocks = frames.map(parseFrame);
    if (blocks.some((x: unknown) => !x)) return json({ error: "Those need to be JPG or PNG images." }, 400);

    const usage = await usageOf(u.id, tier);
    if (usage.blocked) {
      const daily = usage.day_limit != null && usage.day_used >= usage.day_limit && usage.month_used < usage.month_limit;
      return json({ error: daily ? `You've used today's ${usage.day_limit} imports.` : `You've used this month's ${usage.month_limit} imports.`, usage }, 429);
    }
    // hold a place while the AI works; it only becomes a real use once a hook comes back (any failure deletes it)
    const { data: ins, error: insErr } = await admin.from("hook_imports").insert({ user_id: u.id }).select("id").single();
    if (insErr || !ins) return json({ error: "Couldn't start the import." }, 500);
    const refund = () => admin.from("hook_imports").delete().eq("id", ins.id);
    try {

    let res: Response;
    try {
      res = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({
          model: MODEL, max_tokens: 1400, system: SYSTEM, tools: [TOOL], tool_choice: { type: "tool", name: "save_hook" },
          messages: [{ role: "user", content: [...blocks, { type: "text", text: `${blocks.length} frame${blocks.length === 1 ? "" : "s"}, earliest first. What is the hook technique?` }] }],
        }),
        signal: AbortSignal.timeout(55_000),
      });
    } catch (e) { await refund(); console.error("anthropic fetch", e); return json({ error: "The AI took too long. Try again." }, 504); }
    if (!res.ok) { await refund(); console.error("anthropic", res.status, (await res.text()).slice(0, 300)); return json({ error: "The AI service didn't answer. Try again in a moment." }, 502); }
    const out = await res.json();
    const call = (out.content || []).find((c: any) => c.type === "tool_use" && c.name === "save_hook");
    const inp = call && call.input;
    if (!inp || inp.usable === false) {
      await refund();
      return json({ error: str(inp && inp.reason, 160) || "Couldn't find a clear hook in those frames. Try the first few seconds, or add a couple more screenshots.", usable: false, usage: await usageOf(u.id, tier) }, 422);
    }
    const hook = cleanHook(inp);
    if (!hook) { await refund(); return json({ error: "That one didn't come out clearly. Try again.", usable: false, usage: await usageOf(u.id, tier) }, 422); }
    await admin.from("hook_imports").update({ done: true }).eq("id", ins.id);
    return json({ hook, usage: await usageOf(u.id, tier) });
    } catch (e) { await refund(); throw e; }
  } catch (e) {
    console.error(e);
    return json({ error: "Something went wrong." }, 500);
  }
});
