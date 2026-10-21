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
.btn{min-height:40px;}
.modal{padding-top:max(20px,env(safe-area-inset-top));padding-bottom:max(20px,env(safe-area-inset-bottom));padding-left:max(20px,env(safe-area-inset-left));padding-right:max(20px,env(safe-area-inset-right));}
main{padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right));}
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
  // haptics on buttons
  document.addEventListener("pointerdown", function(e){
    try { var b = e.target.closest && e.target.closest("button,.btn"); if (!b) return;
      var H = P("Haptics"); if (H) H.impact({style: b.classList.contains("primary") ? "MEDIUM" : "LIGHT"}); } catch(err){}
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

// 7. Sanity: every inline script still parses
const re = /<script(?![^>]*src=)[^>]*>([\s\S]*?)<\/script>/g; let m, n = 0;
while ((m = re.exec(h))) { try { new Function(m[1]); n++; } catch (e) { console.error("SCRIPT SYNTAX ERROR in block " + n + ": " + e.message); process.exit(1); } }
fs.writeFileSync(file, h);
console.log("patched www/index.html (" + n + " script blocks ok)");
