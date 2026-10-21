/* ================= cloud accounts + sync (iOS app build only) =================
   Local-first: everything still saves to IndexedDB on the device. When signed in, changes are
   queued and pushed to Supabase, and newer cloud copies are pulled down. Works offline. */
const SB_URL = "__SB_URL__";
const SB_KEY = "__SB_KEY__";
const MAX_TRACK_BYTES = 50 * 1024 * 1024;
const QKEY = "producrr_sync_queue_v1";
const sb = (window.supabase && !DEMO_MODE)
  ? window.supabase.createClient(SB_URL, SB_KEY, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false } })
  : null;
let cloudUser = null;
let syncing = false, syncTimer = null, lastPull = 0, cloudMsg = "";

/* ---- queue of pending pushes (survives restarts) ---- */
function qLoad() { try { return JSON.parse(localStorage.getItem(QKEY) || "[]"); } catch (e) { return []; } }
function qSave(q) { try { localStorage.setItem(QKEY, JSON.stringify(q)); } catch (e) {} }
function qAdd(op) {
  if (!sb) return;
  op.n = Date.now() + "-" + Math.random().toString(36).slice(2, 6);
  const q = qLoad().filter(o => !(o.t === op.t && o.k === op.k));
  // a delete supersedes any pending save of the same thing
  const opposite = { p: "pd", pd: "p", t: "td", td: "t" }[op.t];
  qSave(q.filter(o => !(o.t === opposite && o.k === op.k)).concat([op]));
  paintCloud();
}
function trackPath(uidStr, key) { return uidStr + "/" + String(key).replace(/[^A-Za-z0-9_-]/g, "_"); }

/* ---- storage layer: local first, cloud second ---- */
async function listProjects() { return _localListProjects(); }
async function getProjectRecord(id) { return _localGetProjectRecord(id); }
async function putProjectRecord(rec) {
  await _localPutProjectRecord(rec);
  qAdd({ t: "p", k: rec.id }); kickSync();
}
async function deleteProjectRecord(id) {
  await _localDeleteProjectRecord(id);
  qAdd({ t: "pd", k: id, at: new Date().toISOString() }); kickSync();
}
async function saveTrack(projectId, blob, name) {
  await _localSaveTrack(projectId, blob, name);
  qAdd({ t: "t", k: projectId }); kickSync();
}
async function loadTrack(projectId) {
  const local = await _localLoadTrack(projectId);
  if (local || !cloudUser || !sb) return local;
  try {
    const { data: row } = await sb.from("producrr_tracks").select("name,mime").eq("key", projectId).maybeSingle();
    if (!row) return null;
    const { data: blob, error } = await sb.storage.from("tracks").download(trackPath(cloudUser.id, projectId));
    if (error || !blob) return null;
    await _localSaveTrack(projectId, blob, row.name || "track");
    return { blob, name: row.name || "track" };
  } catch (e) { return null; }
}
async function clearTrack(projectId) {
  await _localClearTrack(projectId);
  qAdd({ t: "td", k: projectId }); kickSync();
}

/* ---- pushing ---- */
function kickSync() { clearTimeout(syncTimer); syncTimer = setTimeout(() => { processQueue(); }, 1500); }
async function processQueue() {
  if (!sb || !cloudUser || syncing) return;
  if (navigator.onLine === false) { cloudMsg = "Offline. Changes will sync later."; paintCloud(); return; }
  syncing = true; cloudMsg = "Syncing…"; paintCloud();
  let failed = null;
  try {
    for (let guard = 0; guard < 500; guard++) {
      const q = qLoad(); if (!q.length) break;
      const op = q[0];
      try { await runOp(op); }
      catch (e) { failed = e; break; }
      const done = JSON.stringify(op);
      qSave(qLoad().filter(o => JSON.stringify(o) !== done));
    }
  } finally { syncing = false; }
  cloudMsg = failed ? "Sync paused: " + (failed.message || "network problem") : "";
  paintCloud();
  if (failed) console.error("sync", failed);
}
async function runOp(op) {
  const uidStr = cloudUser.id;
  if (op.t === "p") {
    const rec = await _localGetProjectRecord(op.k);
    if (!rec || isUntouchedExample(rec)) return;
    const { error } = await sb.from("producrr_projects").upsert({ id: rec.id, data: rec, client_updated_at: rec.updatedAt || new Date().toISOString(), deleted_at: null }, { onConflict: "user_id,id" });
    if (error) throw error;
  } else if (op.t === "pd") {
    const { error } = await sb.from("producrr_projects").upsert({ id: op.k, data: {}, client_updated_at: op.at, deleted_at: op.at }, { onConflict: "user_id,id" });
    if (error) throw error;
    const { data: rows } = await sb.from("producrr_tracks").select("key").or("key.eq." + op.k + ",key.like." + op.k + "::*");
    for (const r of rows || []) await removeCloudTrack(r.key);
  } else if (op.t === "t") {
    const t = await _localLoadTrack(op.k);
    if (!t || !t.blob) return;
    if (t.blob.size > MAX_TRACK_BYTES) { console.warn("track too large to sync", t.blob.size); return; }
    const up = await sb.storage.from("tracks").upload(trackPath(uidStr, op.k), t.blob, { upsert: true, contentType: t.blob.type || "audio/mpeg" });
    if (up.error) throw up.error;
    const { error } = await sb.from("producrr_tracks").upsert({ key: op.k, name: t.name || "", size: t.blob.size, mime: t.blob.type || "", updated_at: new Date().toISOString() }, { onConflict: "user_id,key" });
    if (error) throw error;
  } else if (op.t === "td") {
    await removeCloudTrack(op.k);
  }
}
async function removeCloudTrack(key) {
  await sb.storage.from("tracks").remove([trackPath(cloudUser.id, key)]);
  const { error } = await sb.from("producrr_tracks").delete().eq("key", key);
  if (error) throw error;
}
function isUntouchedExample(rec) {
  return !!rec && /^Example (project|content shoot)$/.test(rec.docTitle || "") && rec.createdAt === rec.updatedAt;
}

/* ---- pulling ---- */
async function syncDown(force) {
  if (!sb || !cloudUser) return;
  if (!force && Date.now() - lastPull < 30000) return;
  lastPull = Date.now();
  await processQueue();
  if (qLoad().length) return; // still offline or failing: don't merge on top of unsent changes
  cloudMsg = "Syncing…"; paintCloud();
  try {
    const { data: rows, error } = await sb.from("producrr_projects").select("id,client_updated_at,deleted_at");
    if (error) throw error;
    const local = await _localListProjects();
    const byLocal = new Map(local.map(p => [p.id, p]));
    const cloudIds = new Set();
    const need = [];
    for (const r of rows) {
      cloudIds.add(r.id);
      const l = byLocal.get(r.id);
      const cAt = Date.parse(r.client_updated_at) || 0;
      if (r.deleted_at) {
        if (l && (Date.parse(l.updatedAt) || 0) <= (Date.parse(r.deleted_at) || 0)) await _localDeleteProjectRecord(r.id);
        else if (l) qAdd({ t: "p", k: r.id });
      } else if (!l || cAt > (Date.parse(l.updatedAt) || 0)) {
        if (!(project && project.id === r.id)) need.push(r.id);
      } else if (l && (Date.parse(l.updatedAt) || 0) > cAt) {
        qAdd({ t: "p", k: r.id });
      }
    }
    for (let i = 0; i < need.length; i += 10) {
      const { data: got, error: e2 } = await sb.from("producrr_projects").select("id,data").in("id", need.slice(i, i + 10));
      if (e2) throw e2;
      for (const g of got) if (g.data && g.data.id) await _localPutProjectRecord(g.data);
    }
    // first sign-in on a device with existing local projects: adopt them into the account
    for (const l of local) if (!cloudIds.has(l.id) && !isUntouchedExample(l)) qAdd({ t: "p", k: l.id });
    // local audio tracks the cloud doesn't have yet
    const { data: trows } = await sb.from("producrr_tracks").select("key");
    const haveTracks = new Set((trows || []).map(r => r.key));
    const localKeys = await idb("tracks", "readonly", tx => tx.objectStore("tracks").getAllKeys());
    for (const k of localKeys || []) if (!haveTracks.has(k)) qAdd({ t: "t", k });
    cloudMsg = "";
    paintCloud();
    await processQueue();
    if (!$("projectsView").classList.contains("hidden")) renderProjectsList();
  } catch (e) { cloudMsg = "Sync paused: " + (e.message || "network problem"); paintCloud(); console.error("syncDown", e); }
}

/* ---- local wipe (sign out / switching accounts) ---- */
async function wipeLocal() {
  await idb(["projects", "tracks"], "readwrite", tx => { tx.objectStore("projects").clear(); tx.objectStore("tracks").clear(); });
  try { localStorage.removeItem(QKEY); localStorage.removeItem("shotlist_migrated_v2"); localStorage.removeItem("producrr_content_example_v1"); } catch (e) {}
}

/* ---- account UI ---- */
function paintCloud() {
  const btn = $("accountBtn"); if (!btn) return;
  btn.textContent = cloudUser ? (cloudUser.email || "Account") : "Sign in";
  const pending = qLoad().length;
  const st = $("cloudStatus");
  if (st) st.textContent = !cloudUser ? "" : (cloudMsg || (pending ? pending + " change" + (pending === 1 ? "" : "s") + " waiting to sync" : "Synced"));
  const ms = $("acctSyncLine"); if (ms && st) ms.textContent = st.textContent;
}
function acctShow(view, msg) {
  ["acctSignedOut", "acctSignedIn", "acctCode", "acctReset"].forEach(id => $(id).classList.toggle("hidden", id !== view));
  $("acctMsg").textContent = msg || "";
  $("accountModal").classList.remove("hidden");
  paintCloud();
}
function acctCloseModal() { $("accountModal").classList.add("hidden"); $("acctMsg").textContent = ""; }
let acctMode = "in"; // "in" | "up"
let pendingEmail = "", codeKind = "signup";
function acctSetMode(m) {
  acctMode = m;
  $("acctTabIn").classList.toggle("primary", m === "in");
  $("acctTabUp").classList.toggle("primary", m === "up");
  $("acctSubmit").textContent = m === "in" ? "Sign in" : "Create account";
  $("acctPass").autocomplete = m === "in" ? "current-password" : "new-password";
}
async function acctSubmit() {
  const email = $("acctEmail").value.trim(), pass = $("acctPass").value;
  if (!email || !pass) { $("acctMsg").textContent = "Enter your email and password."; return; }
  if (acctMode === "up" && pass.length < 8) { $("acctMsg").textContent = "Use at least 8 characters."; return; }
  $("acctSubmit").disabled = true; $("acctMsg").textContent = "Working…";
  try {
    if (acctMode === "in") {
      const { error } = await sb.auth.signInWithPassword({ email, password: pass });
      if (error) throw error;
      $("acctPass").value = "";
    } else {
      const { data, error } = await sb.auth.signUp({ email, password: pass });
      if (error) throw error;
      $("acctPass").value = "";
      if (!data.session) { pendingEmail = email; codeKind = "signup"; acctShow("acctCode", "Check your email for a 6-digit code."); }
    }
  } catch (e) { $("acctMsg").textContent = e.message || "That didn't work. Try again."; }
  finally { $("acctSubmit").disabled = false; }
}
async function acctVerifyCode() {
  const token = $("acctCodeInput").value.trim();
  if (token.length < 6) { $("acctMsg").textContent = "Enter the code from the email."; return; }
  $("acctMsg").textContent = "Working…";
  try {
    const { error } = await sb.auth.verifyOtp({ email: pendingEmail, token, type: codeKind });
    if (error) throw error;
    $("acctCodeInput").value = "";
    if (codeKind === "recovery") acctShow("acctReset", "Choose a new password.");
  } catch (e) { $("acctMsg").textContent = e.message || "That code didn't work."; }
}
async function acctSendReset() {
  const email = $("acctEmail").value.trim();
  if (!email) { $("acctMsg").textContent = "Enter your email above first."; return; }
  $("acctMsg").textContent = "Working…";
  try {
    const { error } = await sb.auth.resetPasswordForEmail(email);
    if (error) throw error;
    pendingEmail = email; codeKind = "recovery";
    acctShow("acctCode", "If that email has an account, a 6-digit code is on its way.");
  } catch (e) { $("acctMsg").textContent = e.message || "Couldn't send the email."; }
}
async function acctSetPassword() {
  const p = $("acctNewPass").value;
  if (p.length < 8) { $("acctMsg").textContent = "Use at least 8 characters."; return; }
  try {
    const { error } = await sb.auth.updateUser({ password: p });
    if (error) throw error;
    $("acctNewPass").value = "";
    acctShow("acctSignedIn", "Password updated.");
    syncDown(true);
  } catch (e) { $("acctMsg").textContent = e.message || "Couldn't update the password."; }
}
async function acctSignOut() {
  await processQueue();
  const left = qLoad().length;
  if (left && !confirm(left + " change(s) haven't synced yet and will be lost on this device if you sign out. Sign out anyway?")) return;
  if (project) { try { await persistNow(); } catch (e) {} }
  await sb.auth.signOut({ scope: "local" });
  await wipeLocal();
  location.reload();
}
async function acctDelete() {
  if (!confirm("Delete your account and all of your projects and tracks stored in the cloud? This can't be undone.")) return;
  if (!confirm("Last check: permanently delete this account?")) return;
  $("acctMsg").textContent = "Deleting…";
  try {
    const { data: rows } = await sb.from("producrr_tracks").select("key");
    const paths = (rows || []).map(r => trackPath(cloudUser.id, r.key));
    for (let i = 0; i < paths.length; i += 100) await sb.storage.from("tracks").remove(paths.slice(i, i + 100));
    const { error } = await sb.rpc("delete_my_account");
    if (error) throw error;
    try { localStorage.removeItem(QKEY); } catch (e) {}
    await sb.auth.signOut({ scope: "local" });
    alert("Your account was deleted. The projects already on this device stay here.");
    location.reload();
  } catch (e) { $("acctMsg").textContent = "Couldn't delete the account: " + (e.message || "try again"); }
}
function wireAccountUI() {
  $("accountBtn").addEventListener("click", () => {
    if (!sb) { acctShow("acctSignedOut", "Accounts aren't available in this build."); return; }
    if (cloudUser) { $("acctEmailLine").textContent = cloudUser.email || ""; acctShow("acctSignedIn"); }
    else acctShow("acctSignedOut");
  });
  $("acctClose").addEventListener("click", acctCloseModal);
  $("acctSkip").addEventListener("click", acctCloseModal);
  $("acctDone").addEventListener("click", acctCloseModal);
  $("acctTabIn").addEventListener("click", () => acctSetMode("in"));
  $("acctTabUp").addEventListener("click", () => acctSetMode("up"));
  $("acctSubmit").addEventListener("click", acctSubmit);
  $("acctPass").addEventListener("keydown", e => { if (e.key === "Enter") acctSubmit(); });
  $("acctForgot").addEventListener("click", acctSendReset);
  $("acctCodeGo").addEventListener("click", acctVerifyCode);
  $("acctNewPassGo").addEventListener("click", acctSetPassword);
  $("acctSyncNow").addEventListener("click", () => syncDown(true));
  $("acctSignOut").addEventListener("click", acctSignOut);
  $("acctDelete").addEventListener("click", acctDelete);
  acctSetMode("in");
  paintCloud();
}
async function cloudInit() {
  wireAccountUI();
  if (!sb) return;
  sb.auth.onAuthStateChange((evt, session) => {
    const was = cloudUser;
    cloudUser = session ? session.user : null;
    paintCloud();
    if (cloudUser && (!was || was.id !== cloudUser.id)) {
      if ($("accountModal") && !$("acctCode").classList.contains("hidden") && codeKind === "recovery") return; // stay for new-password step
      acctCloseModal();
      setTimeout(() => syncDown(true), 0);
    }
  });
  try { const { data } = await sb.auth.getSession(); cloudUser = data.session ? data.session.user : null; } catch (e) {}
  paintCloud();
  if (cloudUser) syncDown(true);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") syncDown(false); });
  window.addEventListener("online", () => { kickSync(); syncDown(true); });
}
setTimeout(cloudInit, 0);
