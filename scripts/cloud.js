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
let syncing = false, syncTimer = null, lastPull = 0, cloudMsg = "", syncStartedAt = 0, cloudCheck = null;
function withTimeout(p, ms) { return Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error("timed out")), ms))]); }
/* ask the server what it really has, so the status never says "Synced" just because our own queue is empty */
async function verifyCloud() {
  if (!sb || !cloudUser) { cloudCheck = null; return null; }
  try {
    const [a, b] = await Promise.all([
      sb.from("producrr_projects").select("id,client_updated_at,deleted_at"),
      sb.from("producrr_tracks").select("key")]);
    if (a.error) throw a.error; if (b.error) throw b.error;
    const cloud = new Map((a.data || []).map(r => [r.id, r]));
    const behind = (await _localListProjects()).filter(p => {
      if (isUntouchedExample(p)) return false;
      const c = cloud.get(p.id);
      return !c || (!c.deleted_at && (Date.parse(p.updatedAt) || 0) > (Date.parse(c.client_updated_at) || 0) + 1000);
    });
    const have = new Set((b.data || []).map(r => r.key));
    const keys = await idb("tracks", "readonly", tx => tx.objectStore("tracks").getAllKeys());
    cloudCheck = { projects: behind.map(p => p.docTitle || "Untitled"), tracks: (keys || []).filter(k => !have.has(k)).length, at: Date.now() };
  } catch (e) { cloudCheck = null; }
  paintCloud();
  return cloudCheck;
}
function behindCount() { return cloudCheck ? cloudCheck.projects.length + cloudCheck.tracks : 0; }

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
  if (syncing && Date.now() - syncStartedAt > 90000) syncing = false; // a stuck request must never block saving forever
  if (!sb || !cloudUser || syncing) return;
  if (navigator.onLine === false) { cloudMsg = "Offline. Changes will sync later."; paintCloud(); return; }
  syncing = true; syncStartedAt = Date.now(); cloudMsg = "Syncing…"; paintCloud();
  let failed = null;
  try {
    for (let guard = 0; guard < 500; guard++) {
      const q = qLoad(); if (!q.length) break;
      const op = q[0];
      try { await withTimeout(runOp(op), op.t === "t" ? 180000 : 30000); }
      catch (e) { failed = e; break; }
      const done = JSON.stringify(op);
      qSave(qLoad().filter(o => JSON.stringify(o) !== done));
    }
  } finally { syncing = false; }
  cloudMsg = failed ? "Sync paused: " + (failed.message || "network problem") : "";
  paintCloud();
  if (failed) console.error("sync", failed);
  else verifyCloud();
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
    if (!t || !t.blob || !t.blob.size) return;   // an empty file makes storage answer "No content provided"
    if (t.blob.size > MAX_TRACK_BYTES) { console.warn("track too large to sync", t.blob.size); try { showNotice("A track is over 50 MB, so it can't sync to your account and is only saved on this phone. Re-upload it as an MP3."); } catch (e) {} return; }
    const bytes = await t.blob.arrayBuffer();   // raw bytes: a file-backed Blob can reach storage empty on iOS
    if (!bytes.byteLength) return;
    const up = await sb.storage.from("tracks").upload(trackPath(uidStr, op.k), bytes, { upsert: true, contentType: t.blob.type || "audio/mpeg" });
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
  return !!rec && /^Example (project|content shoot|band)$/.test(rec.docTitle || "") && rec.createdAt === rec.updatedAt;
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
    await verifyCloud();
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
  btn.textContent = cloudUser ? String(cloudUser.email || "A").trim().charAt(0).toUpperCase() : "Sign in";
  btn.classList.toggle("signed", !!cloudUser);
  btn.classList.toggle("warn", !cloudUser ? false : (qLoad().length > 0 || behindCount() > 0));
  btn.title = cloudUser ? (cloudUser.email || "Account") : "Sign in";
  const pending = qLoad().length;
  const st = $("cloudStatus");
  let line = "";
  if (!cloudUser) line = "Only on this phone · sign in to back up";
  else if (cloudMsg) line = cloudMsg;
  else if (pending) line = pending + " change" + (pending === 1 ? "" : "s") + " waiting to sync";
  else if (cloudCheck) {
    const n = behindCount();
    line = n ? "⚠ " + n + " item" + (n === 1 ? "" : "s") + " only on this phone" : "Saved to your account · " + new Date(cloudCheck.at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  } else line = "Checking your account…";
  if (st) st.textContent = line;
  const ms = $("acctSyncLine"); if (ms && st) ms.textContent = st.textContent;
  if (st) st.style.color = cloudUser && !pending && !cloudMsg && cloudCheck && behindCount() ? "var(--danger, #ff6b5e)" : "";
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
  await verifyCloud();
  const left = qLoad().length, c = cloudCheck, names = c ? c.projects.slice(0, 5).join(", ") + (c.tracks ? (c.projects.length ? " and " : "") + c.tracks + " track(s)" : "") : "";
  if ((left || behindCount() || !c) && !confirm((left || behindCount() ? "These aren't saved to your account yet and will be LOST if you sign out: " + (names || left + " change(s)") + ". Sign out anyway?" : "Couldn't confirm that everything is saved to your account. Sign out anyway?"))) return;
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
    if (cloudUser) { $("acctEmailLine").textContent = cloudUser.email || ""; acctShow("acctSignedIn"); verifyCloud(); }
    else acctShow("acctSignedOut");
  });
  $("acctSkip").addEventListener("click", acctCloseModal);
  $("acctTabIn").addEventListener("click", () => acctSetMode("in"));
  $("acctTabUp").addEventListener("click", () => acctSetMode("up"));
  $("acctSubmit").addEventListener("click", acctSubmit);
  $("acctPass").addEventListener("keydown", e => { if (e.key === "Enter") acctSubmit(); });
  $("acctForgot").addEventListener("click", acctSendReset);
  $("acctCodeGo").addEventListener("click", acctVerifyCode);
  $("acctNewPassGo").addEventListener("click", acctSetPassword);
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
    try { window.onCloudUser && window.onCloudUser(cloudUser); } catch (e) {}
    if (cloudUser && (!was || was.id !== cloudUser.id)) {
      if ($("accountModal") && !$("acctCode").classList.contains("hidden") && codeKind === "recovery") return; // stay for new-password step
      acctCloseModal();
      setTimeout(() => syncDown(true), 0);
    }
  });
  try { const { data } = await sb.auth.getSession(); cloudUser = data.session ? data.session.user : null; } catch (e) {}
  paintCloud();
  window.__cloudUserNow = cloudUser;
  if (cloudUser) syncDown(true);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") syncDown(false); });
  window.addEventListener("online", () => { kickSync(); syncDown(true); });
}
window.__cloudToken = async () => { try { const { data } = await sb.auth.getSession(); return data.session ? data.session.access_token : null; } catch (e) { return null; } };
window.__cloudRefresh = async () => { try { await syncDown(true); } catch (e) {} };
window.__cloudOpenAccount = () => acctShow(cloudUser ? "acctSignedIn" : "acctSignedOut");
setTimeout(cloudInit, 0);
