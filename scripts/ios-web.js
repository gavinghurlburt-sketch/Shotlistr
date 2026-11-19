// Copies the built web app into ios/App/App/web, which is checked in, so the iPhone app builds
// straight from an Xcode pull with no Terminal step. Run after `npx cap copy ios` (npm run sync does).
const fs = require("fs");
const path = require("path");
const app = path.join(__dirname, "..", "ios", "App", "App");
const web = path.join(app, "web");
fs.rmSync(path.join(web, "public"), { recursive: true, force: true });
fs.mkdirSync(web, { recursive: true });
fs.cpSync(path.join(app, "public"), path.join(web, "public"), { recursive: true });
for (const f of ["capacitor.config.json", "config.xml"]) fs.copyFileSync(path.join(app, f), path.join(web, f));
console.log("Copied the web app into ios/App/App/web");
