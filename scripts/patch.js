// Generates www/index.html from the web app's index.html. The web version is never edited.
const fs = require("fs");
const file = "www/index.html";
let h = fs.readFileSync(file, "utf8");

function must(label, ok) { if (!ok) { console.error("PATCH FAILED: " + label); process.exit(1); } }
function replaceOnce(label, from, to) {
  must(label, h.includes(from));
  h = h.replace(from, () => to);
}

// 1. Viewport: no zoom of any kind
const vp = '<meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">';
replaceOnce("viewport", '<meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">', vp);

// 2. No service worker inside the native app (assets are bundled)
replaceOnce("service worker guard",
  'location.protocol !== "file:" && !DEMO_MODE',
  'location.protocol !== "file:" && !DEMO_MODE && !(window.Capacitor && Capacitor.isNativePlatform && Capacitor.isNativePlatform())');

// 3. Downloads: iOS web views ignore <a download>. Write to cache, then open the share sheet.
const dl = /function downloadBlob\(blob, name\) \{[\s\S]*?\n\}\n/;
must("downloadBlob", dl.test(h));
h = h.replace(dl, () => `function downloadBlob(blob, name) {
  return nativeSaveBlob(blob, name);
}
`);

// 4. Printing: window.print() does nothing in WKWebView. Use the native print sheet on the live page.
const pr = /function printHTML\(html\) \{[\s\S]*?\n\}\n/;
must("printHTML", pr.test(h));
h = h.replace(pr, () => `function printHTML(html) {
  $("printRoot").innerHTML = html;
  document.body.classList.add("printing");
  nativePrint();
}
`);

// 5. Injected CSS
const css = `<style id="ios-patch">
html{-webkit-text-size-adjust:100%;touch-action:manipulation;}
input,select,textarea{font-size:16px;}
button,.btn{-webkit-tap-highlight-color:transparent;-webkit-user-select:none;user-select:none;}
button:active,.btn:active{transform:scale(.97);opacity:.85;}
@media (hover:none){button:hover,.btn:hover{filter:none;}}
</style>`;
replaceOnce("css", "</head>", css + "\n</head>");

// 6. Injected native bridge script
const js = `<script id="ios-bridge">
(function(){
  function P(n){ try { return (window.Capacitor && Capacitor.Plugins && Capacitor.Plugins[n]) || Capacitor.registerPlugin(n); } catch(e){ return null; } }
  // zoom lock
  ["gesturestart","gesturechange","gestureend"].forEach(function(t){ document.addEventListener(t, function(e){ e.preventDefault(); }, {passive:false}); });
  var last = 0;
  document.addEventListener("touchend", function(e){ var n = Date.now(); if (n - last < 300) e.preventDefault(); last = n; }, {passive:false});
  // click track / cue player must sound with the ring switch on silent
  try { if (navigator.audioSession) navigator.audioSession.type = "playback"; } catch(e){}
  // haptics
  var H = P("Haptics");
  function hap(kind){
    try { if (!H) return;
      if (kind === "marker") H.impact({style:"HEAVY"});
      else if (kind === "measure") H.impact({style:"LIGHT"});
      else if (kind === "primary") H.impact({style:"MEDIUM"});
      else if (kind === "success") H.notification({type:"SUCCESS"});
      else if (kind === "select") H.selectionChanged();
      else H.impact({style:"LIGHT"}); } catch(err){}
  }
  window.nativeHaptic = hap;
  var TAP = "button,.btn,[role=button],.project-card-main,.loc-chip,.tg-block,.tile,.part-chip,.song-tab,.take-pill,.take-btn,.swatch,.board-card,.type-choice,.ws-tab,.vb-item,.ref-thumb,.subtab,summary,label.chk";
  document.addEventListener("pointerdown", function(e){
    try { var b = e.target.closest && e.target.closest(TAP); if (!b || b.disabled) return;
      if (b.closest("canvas")) return;
      if (b.getAttribute && b.getAttribute("data-action") === "toggle-done") return;   // gets its own success buzz on click
      hap(b.classList.contains("primary") ? "primary" : "light"); } catch(err){}
  }, true);
  document.addEventListener("click", function(e){
    try { var d = e.target.closest && e.target.closest('[data-action="toggle-done"]'); if (d) hap("success"); } catch(err){}
  }, true);
  document.addEventListener("change", function(e){
    try { var t = e.target; if (t && (t.tagName === "SELECT" || (t.tagName === "INPUT" && (t.type === "checkbox" || t.type === "radio")))) hap("select"); } catch(err){}
  }, true);
  // save / share a generated file
  window.nativeSaveBlob = function(blob, name){
    return new Promise(function(resolve){
      var r = new FileReader();
      r.onloadend = async function(){
        try {
          var FS = P("Filesystem"), SH = P("Share");
          var data = String(r.result).split(",")[1] || "";
          var res = await FS.writeFile({ path: name, data: data, directory: "CACHE" });
          await SH.share({ title: name, url: res.uri });
        } catch(e) { if (!/cancel/i.test(String(e && e.message))) console.error("share failed", e); }
        resolve();
      };
      r.readAsDataURL(blob);
    });
  };
  // native print sheet for the on-page print layout
  window.nativePrint = async function(){
    try { await P("Printer").printWebView({ name: document.title }); }
    catch(e) { console.error("print failed", e); }
    document.body.classList.remove("printing");
    var pr = document.getElementById("printRoot"); if (pr) pr.innerHTML = "";
  };
})();
</script>`;
replaceOnce("bridge", "</head>", js + "\n</head>");

// 6b. Cloud accounts + sync: rename the local storage functions, then layer the cloud versions on top
const SB_URL = "https://anuybnbilfjthbhsxhdk.supabase.co";
const SB_KEY = "sb_publishable_xVAAW9qGTzEXDptnhK83SA_NTnbC3oj"; // public (publishable) key, safe to ship
const renames = { listProjects: "_localListProjects", getProjectRecord: "_localGetProjectRecord", putProjectRecord: "_localPutProjectRecord", deleteProjectRecord: "_localDeleteProjectRecord", saveTrack: "_localSaveTrack", loadTrack: "_localLoadTrack", clearTrack: "_localClearTrack" };
Object.keys(renames).forEach(k => replaceOnce("rename " + k, "async function " + k + "(", "async function " + renames[k] + "("));
const clearRe = /async function _localClearTrack\(projectId\) \{[\s\S]*?\n\}\n/;
must("clearTrack end", clearRe.test(h));
const cloud = fs.readFileSync("scripts/cloud.js", "utf8").replace("__SB_URL__", SB_URL).replace("__SB_KEY__", SB_KEY);
must("cloud.js has no script end tag", !/<\/script/i.test(cloud));
h = h.replace(clearRe, m => m + "\n" + cloud + "\n");
const lib = fs.readFileSync("scripts/supabase.bundle.js", "utf8");
must("bundle has no script end tag", !/<\/script/i.test(lib));
replaceOnce("supabase lib", "</head>", "<script id=\"supabase-lib\">" + lib + "</script>\n</head>");
replaceOnce("account button", '<button id="themeToggle" class="btn small">Dark mode</button>', '<span id="cloudStatus" class="small"></span><button id="accountBtn" class="btn small">Sign in</button><button id="themeToggle" class="btn small">Dark mode</button>');
replaceOnce("account modal", "</header>", "</header>\n" + fs.readFileSync("scripts/account.html", "utf8"));

// 7. Sanity: every inline script still parses
const re = /<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g; let m, n = 0;
while ((m = re.exec(h))) { try { new Function(m[1]); n++; } catch (e) { console.error("SCRIPT SYNTAX ERROR in block " + n + ": " + e.message); process.exit(1); } }
fs.writeFileSync(file, h);
console.log("patched www/index.html (" + n + " script blocks ok)");
