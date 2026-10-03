// Tests the extension service worker's update logic (build reporting,
// reload into a new build, manual-update fallback) against a mocked chrome
// API. Requires Node 18+.  Usage: node Scripts/extension-tests.mjs
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(process.argv[2] || path.join(here, "../ChromeExtension/service_worker.js"), "utf8");
function makeWorld({ running, brands }) {
  const store = {};
  const calls = { reload: 0, urls: [], badges: [] };
  let status = {};
  const chrome = {
    runtime: {
      getManifest: () => ({ version: running.split(" ")[0], version_name: running }),
      reload: () => { calls.reload++; },
      onInstalled: { addListener() {} }, onStartup: { addListener() {} }, onMessage: { addListener() {} },
    },
    storage: {
      local: {
        get: (keys, cb) => {
          const list = Array.isArray(keys) ? keys : [keys];
          const out = {}; for (const k of list) if (k in store) out[k] = structuredClone(store[k]);
          if (cb) { cb(out); return; } return Promise.resolve(out);
        },
        set: (obj, cb) => { Object.assign(store, structuredClone(obj)); if (cb) { cb(); return; } return Promise.resolve(); },
        remove: (k) => { delete store[k]; return Promise.resolve(); },
      },
      session: { get: async () => ({}), set: async () => {}, remove: async () => {} },
    },
    proxy: { settings: { set: (_v, cb) => cb() } },
    alarms: { create() {}, onAlarm: { addListener() {} } },
    tabs: { query: async () => [], get: async () => ({}), onActivated: { addListener() {} }, onUpdated: { addListener() {} }, onRemoved: { addListener() {} } },
    action: { setBadgeText: async (b) => calls.badges.push(b.text), setBadgeBackgroundColor: async () => {}, setTitle: async () => {} },
  };
  const fetch = async (url) => {
    calls.urls.push(url);
    const body = url.includes("/status") ? status : { domains: [], revision: 1 };
    return { ok: true, json: async () => body };
  };
  const ctx = vm.createContext({
    chrome, fetch, console, setTimeout, clearTimeout, AbortController, URL, structuredClone,
    crypto: { randomUUID: () => "instance-uuid-1" },
    navigator: { userAgentData: { brands } },
  });
  vm.runInContext(src, ctx);
  return { ctx, store, calls, setStatus: (s) => { status = s; } };
}
const settle = () => new Promise((r) => setTimeout(r, 20));
let failures = 0;
const check = (name, cond) => { console.log((cond ? "PASS  " : "FAIL  ") + name); if (!cond) failures++; };

// Chrome, running the old build; the app installed a new one.
{
  const w = makeWorld({ running: "0.3.0 (aaaaaaa)", brands: [{ brand: "Not)A;Brand" }, { brand: "Google Chrome" }, { brand: "Chromium" }] });
  w.setStatus({ extensionBuild: "0.3.0 (aaaaaaa)" });
  await settle();   // the start-up sync
  check("reports instance, brand and build on /status",
    w.calls.urls.some((u) => u.includes("/status?instance=instance-uuid-1&browser=Google%20Chrome&build=0.3.0%20(aaaaaaa)")));
  check("no reload when the folder has the running build", w.calls.reload === 0);

  w.setStatus({ extensionBuild: "0.4.0 (bbbbbbb)" });
  await w.ctx.syncFromApp(); await settle();
  check("reloads once for a new build", w.calls.reload === 1 && w.store.semiVPNExtensionUpdate?.target === "0.4.0 (bbbbbbb)");

  // The reload did not change the running build (loaded from another folder).
  await w.ctx.syncFromApp(); await settle();
  check("does not reload again for the same build", w.calls.reload === 1);
  check("asks for a manual update instead", w.store.semiVPNExtensionUpdate?.manual === true);
  check("manualUpdateNeeded() is true", await w.ctx.manualUpdateNeeded() === true);

  w.setStatus({ extensionBuild: "0.5.0 (ccccccc)" });
  await w.ctx.syncFromApp(); await settle();
  check("reloads again for the next build", w.calls.reload === 2 && w.store.semiVPNExtensionUpdate?.manual === false);
}
// After the reload the new build runs: the state is cleared.
{
  const w = makeWorld({ running: "0.4.0 (bbbbbbb)", brands: [{ brand: "Microsoft Edge" }, { brand: "Chromium" }, { brand: "Not A(Brand" }] });
  w.store.semiVPNExtensionUpdate = { target: "0.4.0 (bbbbbbb)", manual: false };
  w.setStatus({ extensionBuild: "0.4.0 (bbbbbbb)" });
  await settle();
  check("clears the update state once the new build runs", !("semiVPNExtensionUpdate" in w.store) && w.calls.reload === 0);
  check("reports Microsoft Edge as the brand", w.calls.urls.some((u) => u.includes("browser=Microsoft%20Edge")));
}
// An older app (no extensionBuild in its status) never triggers a reload.
{
  const w = makeWorld({ running: "0.4.0 (bbbbbbb)", brands: [] });
  w.setStatus({});
  await settle();
  check("no reload without extensionBuild", w.calls.reload === 0);
  check("falls back to Chromium when no brand is known", w.calls.urls.some((u) => u.includes("browser=Chromium")));
}
console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
