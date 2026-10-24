// Builds site/ for Vercel: one project, three addresses (see vercel.json).
//   creatrr.co        landing page
//   app.creatrr.co    the web app (patched build: accounts, sync, plan from the App Store)
//   band.creatrr.co   the band's temporary page (the plain app, no accounts)
const fs = require("fs"), cp = require("child_process");
const sh = c => cp.execSync(c, { stdio: "inherit" });
fs.rmSync("site", { recursive: true, force: true });
fs.mkdirSync("site");
sh("npx esbuild scripts/supabase-entry.js --bundle --minify --format=iife --outfile=scripts/supabase.bundle.js --log-level=warning");
fs.copyFileSync("index.html", "site/app.html");
sh("WEB=1 PATCH_FILE=site/app.html node scripts/patch.js");
fs.copyFileSync("index.html", "site/band.html");
fs.copyFileSync("landing.html", "site/home.html");
fs.copyFileSync("band-landing.html", "site/band-home.html");
["manifest.json", "service-worker.js"].forEach(f => fs.copyFileSync(f, "site/" + f));
["assets", "docs", "icons"].forEach(d => fs.cpSync(d, "site/" + d, { recursive: true }));
console.log("site/ ready");
