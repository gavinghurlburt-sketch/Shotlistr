/* ================= subscriptions (iOS app build only) =================
   RevenueCat + App Store. Off until scripts/subs.config.json says "live": true, so the app behaves exactly as before.
   RevenueCat setup: entitlements named artist / plus / pro, each attached to its monthly product. */
const SUBS_LIVE = __SUBS_LIVE__;
const RC_API_KEY = "__RC_KEY__";
const TIER_RANK = { artist: 1, plus: 2, pro: 3 };
const TIER_PRODUCT = { artist: "creatrr_artist_monthly", plus: "creatrr_plus_monthly", pro: "creatrr_pro_monthly" };
const TIER_BLURB = {
  artist: "One artist. Plan every shoot for your own music.",
  plus: "Up to 10 artists. Every shoot tool, unlimited songs.",
  pro: "Up to 50 artists, plus Video production with call sheets and an on-set tracker."
};
const TIER_PRICE_FALLBACK = { artist: "$1.99", plus: "$9.99", pro: "$29.99" };
const LEGAL_BASE = "https://gavinghurlburt-sketch.github.io/Shotlistr/docs/";
const TIER_CACHE_KEY = "creatrr_plan_cache_v1";
let subs = { tier: null, trial: false, loaded: false }, rcOfferings = null, pwBlocking = false, pwBusy = false, rcLoggedIn = false;
const rcApi = () => window.__RC_MOCK || window.RC;

function tierFromInfo(info) {
  const act = (info && info.entitlements && info.entitlements.active) || {};
  let best = null;
  Object.keys(TIER_RANK).forEach(t => { if (act[t] && (!best || TIER_RANK[t] > TIER_RANK[best])) best = t; });
  return { tier: best, trial: !!(best && String(act[best].periodType || "").toLowerCase() === "trial") };
}
function cachePlan(tier) { try { localStorage.setItem(TIER_CACHE_KEY, JSON.stringify({ tier, at: Date.now() })); } catch (e) {} }
function cachedPlan() {              // lets someone who is offline keep working for up to 7 days
  try { const c = JSON.parse(localStorage.getItem(TIER_CACHE_KEY) || "null"); if (c && TIER_RANK[c.tier] && Date.now() - c.at < 7 * 864e5) return c.tier; } catch (e) {}
  return null;
}
function handleCustomerInfo(info) {
  const r = tierFromInfo(info);
  subs = { tier: r.tier, trial: r.trial, loaded: true };
  cachePlan(r.tier);
  if (r.tier) { setTier(r.tier); closePaywall(true); } else openPaywall(true);
  paintPlanRow();
}

/* ---- paywall ---- */
function ensurePaywall() {
  if ($("paywall")) return $("paywall");
  const st = document.createElement("style");
  st.textContent = `
  #paywall{position:fixed;inset:0;z-index:100000;background:var(--bg);overflow-y:auto;-webkit-overflow-scrolling:touch;padding:calc(env(safe-area-inset-top) + 22px) 18px calc(env(safe-area-inset-bottom) + 28px)}
  #paywall .pw-in{max-width:520px;margin:0 auto}
  #paywall h2{font-size:28px;letter-spacing:-.03em;margin:6px 0 4px}
  #paywall .pw-sub{color:var(--muted);margin:0 0 18px}
  .pw-card{background:var(--surface);border-radius:24px;padding:16px 18px;margin:0 0 12px;border:2px solid transparent}
  .pw-card.cur{border-color:var(--accent)} .pw-card.pop{border-color:color-mix(in srgb,var(--accent) 55%,transparent)}
  .pw-top{display:flex;align-items:baseline;gap:10px} .pw-name{font-size:19px;font-weight:800} .pw-price{margin-left:auto;font-weight:800;font-size:19px}
  .pw-price small{font-weight:600;color:var(--muted);font-size:13px}
  .pw-blurb{color:var(--muted);margin:4px 0 12px;font-size:14.5px}
  .pw-tag{font-size:11px;font-weight:800;letter-spacing:.06em;text-transform:uppercase;background:var(--accent);color:var(--accent-fg);border-radius:999px;padding:2px 9px}
  .pw-buy{width:100%;min-height:50px;justify-content:center;font-size:16px;font-weight:700}
  #paywall .pw-links{display:flex;flex-wrap:wrap;gap:8px 18px;justify-content:center;margin:14px 0 8px}
  #paywall .pw-links button,#paywall .pw-links a{background:none;border:0;color:var(--text);font:inherit;font-weight:600;text-decoration:underline;padding:6px}
  #paywall .pw-legal{color:var(--muted);font-size:12px;line-height:1.5;text-align:center}
  #paywall .pw-msg{min-height:1.3em;text-align:center;margin:6px 0;font-weight:600}
  #acctPlanRow{margin:0 0 10px}`;
  document.head.appendChild(st);
  const el = document.createElement("div"); el.id = "paywall"; el.className = "hidden";
  el.addEventListener("click", onPaywallClick);
  document.body.appendChild(el);
  return el;
}
function pkgFor(tier) {
  const pk = (rcOfferings && rcOfferings.current && rcOfferings.current.availablePackages) || [];
  return pk.find(p => p.product && p.product.identifier === TIER_PRODUCT[tier]) || null;
}
function paintPaywall(msg) {
  const el = ensurePaywall();
  const cards = ["artist", "plus", "pro"].map(t => {
    const pk = pkgFor(t), price = pk ? pk.product.priceString : TIER_PRICE_FALLBACK[t];
    const trial = !!(pk && pk.product.introPrice), cur = subs.tier === t;
    const label = cur ? "Your plan" : (trial && !subs.tier ? "Start 7-day free trial" : (subs.tier && TIER_RANK[t] < TIER_RANK[subs.tier] ? "Switch to " + TIERS[t].name.replace("creatrr ", "") : (subs.tier ? "Upgrade" : "Subscribe")));
    return `<div class="pw-card${cur ? " cur" : t === "plus" && !subs.tier ? " pop" : ""}">
      <div class="pw-top"><span class="pw-name">${TIERS[t].name}</span>${t === "plus" && !cur ? '<span class="pw-tag">Popular</span>' : ""}<span class="pw-price">${price}<small> /month</small></span></div>
      <p class="pw-blurb">${TIER_BLURB[t]}</p>
      <button type="button" class="btn ${cur ? "" : "primary"} pw-buy" data-pw-buy="${t}"${cur || pwBusy ? " disabled" : ""}>${label}</button></div>`;
  }).join("");
  el.innerHTML = `<div class="pw-in">
    ${pwBlocking ? "" : '<div style="text-align:right"><button type="button" class="btn small" data-pw="close">Close</button></div>'}
    <h2>${subs.tier ? "Your plan" : "Pick your plan"}</h2>
    <p class="pw-sub">${subs.tier ? "You're on " + TIERS[subs.tier].name + (subs.trial ? " (free trial)" : "") + "." : "Plan every shoot in one place. Unlimited songs on every plan."}</p>
    ${cards}
    <div class="pw-msg" id="pwMsg">${msg || ""}</div>
    <div class="pw-links">
      <button type="button" data-pw="restore">Restore purchases</button>
      ${subs.tier ? '<button type="button" data-pw="manage">Manage subscription</button>' : ""}
      <button type="button" data-pw="export">Export my projects</button>
    </div>
    <p class="pw-legal">Payment is charged to your Apple ID at confirmation of purchase, or when a free trial ends. Subscriptions renew every month unless cancelled at least 24 hours before the end of the current period. Manage or cancel any time in Settings → your name → Subscriptions.</p>
    <div class="pw-links"><a href="${LEGAL_BASE}terms.html" target="_blank" rel="noopener">Terms of Use</a><a href="${LEGAL_BASE}privacy.html" target="_blank" rel="noopener">Privacy Policy</a></div>
  </div>`;
}
async function loadOfferings() {
  try { rcOfferings = await rcApi().getOfferings(); } catch (e) { rcOfferings = null; }
}
async function openPaywall(blocking) {
  if (!SUBS_LIVE) return;
  pwBlocking = !!blocking && !subs.tier;
  ensurePaywall().classList.remove("hidden"); paintPaywall("");
  if (!rcOfferings) { await loadOfferings(); paintPaywall(rcOfferings ? "" : "Couldn't load prices. Check your connection."); }
}
function closePaywall(force) {
  if (!force && pwBlocking) return;
  const el = $("paywall"); if (el) el.classList.add("hidden");
}
async function onPaywallClick(e) {
  const buy = e.target.closest("[data-pw-buy]"), act = e.target.closest("[data-pw]");
  if (buy && !pwBusy) {
    const t = buy.dataset.pwBuy, pk = pkgFor(t);
    if (!pk) { paintPaywall("Couldn't load this plan. Check your connection and try again."); loadOfferings().then(() => paintPaywall("")); return; }
    pwBusy = true; paintPaywall("Opening the App Store…");
    try { const r = await rcApi().purchasePackage({ aPackage: pk }); pwBusy = false; handleCustomerInfo(r.customerInfo); if (subs.tier) paintPaywall("You're all set."); }
    catch (err) { pwBusy = false; paintPaywall(err && err.userCancelled ? "" : "The purchase didn't go through. You weren't charged."); }
    return;
  }
  if (!act) return;
  const k = act.dataset.pw;
  if (k === "close") closePaywall(true);
  else if (k === "restore") {
    paintPaywall("Looking for your purchases…");
    try { const r = await rcApi().restorePurchases(); handleCustomerInfo(r.customerInfo); if (!subs.tier) paintPaywall("No active subscription found for this Apple ID."); else paintPaywall("Purchases restored."); }
    catch (err) { paintPaywall("Couldn't restore. Check your connection and try again."); }
  }
  else if (k === "manage") { try { await rcApi().showManageSubscriptions(); } catch (err) { paintPaywall("Open Settings → your name → Subscriptions to manage your plan."); } }
  else if (k === "export") exportAllProjects();
}
async function exportAllProjects() {
  try {
    const all = (await listProjects()).filter(r => !isUntouchedExample(r));
    const blob = new Blob([JSON.stringify({ creatrr: 1, exportedAt: new Date().toISOString(), projects: all })], { type: "application/json" });
    await downloadBlob(blob, "creatrr-all-projects.json");
    paintPaywall("Your projects were exported. Audio stays in your account.");
  } catch (e) { paintPaywall("Couldn't export. Try again."); }
}

/* ---- account screen: plan row ---- */
function paintPlanRow() {
  const row = $("acctPlanRow"); if (!row) return;
  row.innerHTML = `<div class="muted small" style="margin-bottom:6px">Plan</div><div style="display:flex;align-items:center;gap:10px"><b>${subs.tier ? TIERS[subs.tier].name + (subs.trial ? " · trial" : "") : "No plan"}</b><span class="spacer" style="flex:1"></span><button type="button" class="btn small" id="acctPlanBtn">${subs.tier ? "Change plan" : "Choose a plan"}</button></div>`;
  $("acctPlanBtn").addEventListener("click", () => { acctCloseModal(); openPaywall(false); });
}

/* ---- startup ---- */
async function subsInit() {
  if (!SUBS_LIVE) return;
  document.querySelectorAll("[data-tier-pref]").forEach(b => { const seg = b.closest(".theme-seg"); if (seg) { if (seg.previousElementSibling) seg.previousElementSibling.remove(); seg.remove(); } });   // the testing plan switcher goes away
  const sa = $("acctSyncLine");
  if (sa && !$("acctPlanRow")) { sa.insertAdjacentHTML("afterend", '<div id="acctPlanRow"></div>'); }
  ensurePaywall();
  const cached = cachedPlan(); if (cached) setTier(cached);
  try {
    const api = rcApi();
    await api.configure({ apiKey: RC_API_KEY });
    api.addCustomerInfoUpdateListener(info => handleCustomerInfo(info));
    if (window.__cloudUserNow && !rcLoggedIn) { await onCloudUser(window.__cloudUserNow); }
    else { const r = await api.getCustomerInfo(); handleCustomerInfo(r.customerInfo); }
    loadOfferings();
  } catch (e) {
    console.error("purchases", e);
    if (!cached) { subs.loaded = true; openPaywall(true); }        // no cached plan and can't reach the store
  }
}
async function onCloudUser(u) {                                     // called by the account code when the signed-in user changes
  window.__cloudUserNow = u || null;
  if (!SUBS_LIVE || !subs) return;
  try {
    const api = rcApi();
    if (u) { const r = await api.logIn({ appUserID: u.id }); rcLoggedIn = true; handleCustomerInfo(r.customerInfo); }
    else if (rcLoggedIn) { rcLoggedIn = false; const r = await api.logOut(); handleCustomerInfo(r.customerInfo); }
  } catch (e) { console.error("purchases login", e); }
}
window.onCloudUser = onCloudUser;
setTimeout(subsInit, 0);
