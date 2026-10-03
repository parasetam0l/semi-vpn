// Tests the extension service worker's update logic (build reporting and
// the Extensions-page update prompt) and its routing badges
// against a mocked chrome API. Requires Node 18+.  Usage: node Scripts/extension-tests.mjs
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
  let domains = { domains: [], revision: 1 };
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
    const body = url.includes("/status") ? status : domains;
    return { ok: true, json: async () => body };
  };
  const ctx = vm.createContext({
    chrome, fetch, console, setTimeout, clearTimeout, AbortController, URL, structuredClone,
    crypto: { randomUUID: () => "instance-uuid-1" },
    navigator: { userAgentData: { brands } },
  });
  vm.runInContext(src, ctx);
  return { ctx, store, calls, setStatus: (s) => { status = s; }, setDomains: (d) => { domains = d; } };
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
  check("no update state when the folder has the running build", !("semiVPNExtensionUpdate" in w.store));

  w.setStatus({ extensionBuild: "0.4.0 (bbbbbbb)" });
  await w.ctx.syncFromApp(); await settle();
  check("never calls chrome.runtime.reload (it does not load new unpacked files)", w.calls.reload === 0);
  check("asks for a reload on the Extensions page", w.store.semiVPNExtensionUpdate?.target === "0.4.0 (bbbbbbb)");
  check("manualUpdateNeeded() is true", await w.ctx.manualUpdateNeeded() === true);
  w.calls.badges.length = 0;
  await w.ctx.updateBadgeForTab(3, "chrome://newtab/");
  check("tabs without a routing badge show UPD", w.calls.badges.at(-1) === "UPD");
}
// After the reload the new build runs: the state is cleared.
{
  const w = makeWorld({ running: "0.4.0 (bbbbbbb)", brands: [{ brand: "Microsoft Edge" }, { brand: "Chromium" }, { brand: "Not A(Brand" }] });
  w.store.semiVPNExtensionUpdate = { target: "0.4.0 (bbbbbbb)", manual: true };
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
  check("no update state without extensionBuild", !("semiVPNExtensionUpdate" in w.store));
  check("falls back to Chromium when no brand is known", w.calls.urls.some((u) => u.includes("browser=Chromium")));
}
// Badges while the VPN is up but macOS routes SemiVPN's proxy outside it.
{
  const w = makeWorld({ running: "0.4.0 (bbbbbbb)", brands: [{ brand: "Google Chrome" }] });
  w.setDomains({ domains: ["icanhazip.com"], subdomainDomains: [], inactiveDomains: [], revision: 2 });
  const badgeFor = async (status) => {
    w.setStatus({ extensionBuild: "0.4.0 (bbbbbbb)", routingMode: "browser-only", forwardingAllowed: true, ...status });
    await w.ctx.syncFromApp(); await settle();
    w.calls.badges.length = 0;
    await w.ctx.updateBadgeForTab(7, "https://icanhazip.com/");
    return w.calls.badges.at(-1);
  };
  check("listed site shows ON through the VPN", await badgeFor({ tunnelBypassed: false }) === "ON");
  check("listed site shows ! when the proxy is outside the VPN", await badgeFor({ tunnelBypassed: true }) === "!");
  check("listed site shows BLK when that also blocks it",
    await badgeFor({ tunnelBypassed: true, blockWhenDisconnected: true }) === "BLK");
}
console.log(failures ? `\n${failures} failed` : "\nall passed");
process.exit(failures ? 1 : 0);
