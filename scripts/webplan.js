/* ================= plan on the web (browser build only) =================
   Plans are bought in the App Store. The web asks the server which plan this account has.
   Off until scripts/subs.config.json says "live": true, same switch as the app. */
const SUBS_LIVE = __SUBS_LIVE__;
const WEB_PLAN_KEY = "creatrr_web_plan_v1";
function webGateEl() {
  let el = document.getElementById("webGate");
  if (el) return el;
  const st = document.createElement("style");
  st.textContent = "#webGate{position:fixed;inset:0;z-index:100000;background:var(--bg);display:flex;align-items:center;justify-content:center;padding:28px;text-align:center}#webGate>div{max-width:360px}#webGate h2{font-size:26px;letter-spacing:-.02em;margin:0 0 8px}#webGate p{color:var(--muted);margin:0 0 18px}#webGate .btn{min-width:180px;justify-content:center;margin:4px}#accountModal{z-index:100001}";
  document.head.appendChild(st);
  el = document.createElement("div"); el.id = "webGate"; el.className = "hidden";
  document.body.appendChild(el);
  el.addEventListener("click", e => {
    const b = e.target.closest("[data-wg]"); if (!b) return;
    if (b.dataset.wg === "in") acctShow("acctSignedOut");
    else if (b.dataset.wg === "out") acctSignOut();
    else if (b.dataset.wg === "retry") webCheck(window.__cloudUserNow);
  });
  return el;
}
function webGate(h, p, btns) {
  const el = webGateEl();
  el.innerHTML = "<div><h2>" + h + "</h2><p>" + p + "</p>" + (btns || "") + "</div>";
  el.classList.remove("hidden");
}
function webGateOff() { const el = document.getElementById("webGate"); if (el) el.classList.add("hidden"); }
async function webCheck(u) {
  window.__webChecked = true;
  window.__cloudUserNow = u || null;
  if (!SUBS_LIVE) return;
  if (!u) { webGate("Sign in to open creatrr", "Use the same account as the iPhone app.", '<button type="button" class="btn primary" data-wg="in">Sign in</button>'); return; }
  webGate("Checking your plan…", "One moment.");
  try {
    const { data } = await sb.auth.getSession(), tok = data.session && data.session.access_token;
    const r = await fetch(SB_URL + "/functions/v1/my-plan", { method: "POST", headers: { "Content-Type": "application/json", apikey: SB_KEY, Authorization: "Bearer " + tok }, body: "{}" });
    if (!r.ok) { let why = ""; try { why = (await r.json()).error || ""; } catch (e) {} const er = new Error("plan check " + r.status + (why ? " " + why : "")); er.code = r.status + (why ? " · " + why : ""); throw er; }
    const j = await r.json();
    if (j.tier && TIERS[j.tier]) { try { localStorage.setItem(WEB_PLAN_KEY, JSON.stringify({ tier: j.tier, at: Date.now() })); } catch (e) {} setTier(j.tier); webGateOff(); return; }
    webGate("No active plan", "Plans are bought in the creatrr iPhone app. Subscribe there, then come back and open this page again.", '<button type="button" class="btn primary" data-wg="retry">Check again</button><button type="button" class="btn" data-wg="out">Sign out</button>');
  } catch (e) {
    let c = null; try { c = JSON.parse(localStorage.getItem(WEB_PLAN_KEY) || "null"); } catch (er) {}
    if (c && TIERS[c.tier] && Date.now() - c.at < 7 * 864e5) { setTier(c.tier); webGateOff(); return; }   // offline: the last plan keeps working for a week
    webGate("Couldn't check your plan", "Check your connection and try again." + (e && e.code ? " (" + e.code + ")" : ""), '<button type="button" class="btn primary" data-wg="retry">Try again</button>');
  }
}
window.onCloudUser = webCheck;
if (SUBS_LIVE) setTimeout(() => { document.querySelectorAll("[data-tier-pref]").forEach(b => { const seg = b.closest(".theme-seg"); if (seg) { if (seg.previousElementSibling) seg.previousElementSibling.remove(); seg.remove(); } }); const sk = document.getElementById("acctSkip"); if (sk) sk.remove(); if (window.__webChecked) webCheck(window.__cloudUserNow); else webGate("Loading…", ""); }, 0);
// if the sign-in code never reports back, ask for the session ourselves so the page can't sit on "Loading…"
if (SUBS_LIVE) setTimeout(async () => {
  if (window.__webChecked) return;
  let u = null;
  try { const { data } = await sb.auth.getSession(); u = data.session ? data.session.user : null; } catch (e) {}
  if (!window.__webChecked) webCheck(u);
}, 1200);
