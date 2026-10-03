const API_ENDPOINTS = [
  "http://127.0.0.1:49281/v1",
  "http://[::1]:49281/v1"
];
const PROXY_HOST = "127.0.0.1";
const PROXY_PORT = 49280;
const CACHE_KEY = "semiVPNDomainConfiguration";
const INSTANCE_KEY = "semiVPNInstance";
const UPDATE_KEY = "semiVPNExtensionUpdate";
const MANIFEST = chrome.runtime.getManifest();
// The build this browser runs: the version_name the SemiVPN app build stamps
// from the extension's files ("0.4.0 (1a2b3c4)"), else the version.
const RUNNING_BUILD = MANIFEST.version_name || MANIFEST.version;
let syncChain = Promise.resolve();

function getStoredConfiguration() {
  return new Promise((resolve) => {
    chrome.storage.local.get([CACHE_KEY], (result) => {
      resolve(result[CACHE_KEY] || { domains: [], revision: 0 });
    });
  });
}

function storeConfiguration(configuration) {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [CACHE_KEY]: configuration }, resolve);
  });
}

function setProxy(value) {
  return new Promise((resolve, reject) => {
    chrome.proxy.settings.set({ value, scope: "regular" }, () => {
      if (chrome.runtime.lastError) {
        reject(new Error(chrome.runtime.lastError.message));
      } else {
        resolve();
      }
    });
  });
}

function routingMode(configuration) {
  if (typeof configuration.routingMode === "string") return configuration.routingMode;
  if (configuration.fullTunnel === true) return "all-apps";
  if (configuration.domainRouting === true) return "selected-apps-and-browser";
  return "selected-apps-only";
}

function browserModeEnabled(configuration) {
  return ["selected-apps-and-browser", "browser-only"].includes(routingMode(configuration));
}

// The inactive list is the persisted policy. Active lists are derived values
// and must never be allowed to resurrect a paused domain from stale cache or
// from an out-of-order API response.
function normalizeDomainConfiguration(configuration = {}) {
  const domains = Array.isArray(configuration.domains) ? [...new Set(configuration.domains)] : [];
  const subdomainDomains = (Array.isArray(configuration.subdomainDomains)
    ? configuration.subdomainDomains
    : domains).filter((domain) => domains.includes(domain));
  const inactiveDomains = Array.isArray(configuration.inactiveDomains)
    ? configuration.inactiveDomains.filter((domain) => domains.includes(domain))
    : domains.filter((domain) => Array.isArray(configuration.activeDomains)
      ? !configuration.activeDomains.includes(domain)
      : false);
  const activeDomains = domains.filter((domain) => !inactiveDomains.includes(domain));
  const activeSubdomainDomains = subdomainDomains.filter((domain) => !inactiveDomains.includes(domain));
  return {
    ...configuration,
    domains,
    inactiveDomains,
    subdomainDomains,
    activeDomains,
    activeSubdomainDomains
  };
}

// Listed domains always go to the local proxy, which decides per
// connection: through the VPN when it is connected; otherwise directly, or
// blocked when the user chose to fail closed. With fail-closed there is no
// DIRECT fallback either, so a stopped proxy cannot leak listed domains.
function pacForDomains(domains, subdomainDomains = domains, blockWhenDisconnected = false) {
  const serializedDomains = JSON.stringify(domains);
  const serializedSubdomainDomains = JSON.stringify(subdomainDomains);
  const route = "PROXY [::1]:" + PROXY_PORT + "; PROXY " + PROXY_HOST + ":" + PROXY_PORT +
    (blockWhenDisconnected ? "" : "; DIRECT");
  return "function FindProxyForURL(url, host) {" +
    " host = (host || '').toLowerCase().replace(/\\.$/, '');" +
    " var domains = " + serializedDomains + ";" +
    " var subdomainDomains = " + serializedSubdomainDomains + ";" +
    " for (var i = 0; i < domains.length; i++) {" +
    "   if (host === domains[i] || host === 'www.' + domains[i] ||" +
    "       (subdomainDomains.indexOf(domains[i]) !== -1 && dnsDomainIs(host, '.' + domains[i]))) {" +
    "     return '" + route + "';" +
    "   }" +
    " }" +
    " return 'DIRECT';" +
    "}";
}

async function applyConfiguration(configuration) {
  const normalized = normalizeDomainConfiguration(configuration);
  const { domains, inactiveDomains, subdomainDomains, activeDomains, activeSubdomainDomains } = normalized;
  const mode = routingMode(configuration);
  const forwardingAllowed = configuration.forwardingAllowed === true;
  const browserRoutingEnabled = browserModeEnabled(configuration);
  const blockWhenDisconnected = configuration.blockWhenDisconnected === true;
  // The proxy, not the PAC, follows the VPN state: listing the domains only
  // while connected left them DIRECT until the next sync after connecting.
  const proxyDomains = browserRoutingEnabled ? activeDomains : [];
  const proxySubdomainDomains = browserRoutingEnabled ? activeSubdomainDomains : [];
  await setProxy({
    mode: "pac_script",
    pacScript: { data: pacForDomains(proxyDomains, proxySubdomainDomains, blockWhenDisconnected), mandatory: true }
  });
  await storeConfiguration({
    domains,
    inactiveDomains,
    activeDomains,
    subdomainDomains,
    activeSubdomainDomains,
    routingMode: mode,
    browserRoutingEnabled,
    forwardingAllowed,
    blockWhenDisconnected,
    revision: configuration.revision || 0,
    updatedAt: configuration.updatedAt || null,
    lastSyncSucceeded: true
  });
  updateAllActiveTabBadges().catch(() => {});
  return {
    ...normalized,
    routingMode: mode,
    browserRoutingEnabled
  };
}

async function apiFetch(path) {
  let lastError = null;
  for (const base of API_ENDPOINTS) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 1500);
    try {
      const response = await fetch(base + path, {
        signal: controller.signal,
        cache: "no-store"
      });
      if (!response.ok) throw new Error("SemiVPN API returned " + response.status);
      return await response.json();
    } catch (err) {
      lastError = err;
    } finally {
      clearTimeout(timeoutId);
    }
  }
  throw lastError || new Error("SemiVPN API unreachable");
}

// The browser's brand ("Google Chrome", "Microsoft Edge", "Brave", ...),
// skipping Chromium and the randomized "Not A Brand" entries.
function browserName() {
  const brands = (navigator.userAgentData && navigator.userAgentData.brands) || [];
  const named = brands.map((entry) => entry.brand).filter((name) => !/not.?a.?brand|^chromium$/i.test(name));
  return named[0] || "Chromium";
}

// A random ID per browser profile, so the app can list each one.
async function instanceID() {
  const stored = (await chrome.storage.local.get(INSTANCE_KEY))[INSTANCE_KEY];
  if (stored) return stored;
  const id = crypto.randomUUID();
  await chrome.storage.local.set({ [INSTANCE_KEY]: id });
  return id;
}

// Tells the app which build this profile runs, with every status request.
async function reportQuery() {
  const fields = { instance: await instanceID(), browser: browserName(), build: RUNNING_BUILD };
  return Object.entries(fields).map(([key, value]) => key + "=" + encodeURIComponent(value)).join("&");
}

async function fetchConfiguration() {
  const [status, domainConfiguration] = await Promise.all([
    apiFetch("/status?" + await reportQuery()),
    apiFetch("/domains")
  ]);
  return normalizeDomainConfiguration({ ...status, ...domainConfiguration });
}

// The SemiVPN app copies each new extension build into the folder this
// extension is loaded from (extensionBuild in its status), so a reload picks
// it up. One reload per build: when it does not help, the browser loads the
// extension from another folder, and the popup and badge ask the user to
// update it by hand instead.
async function checkForNewBuild(configuration) {
  const target = configuration.extensionBuild;
  const stored = (await chrome.storage.local.get(UPDATE_KEY))[UPDATE_KEY] || null;
  if (!target || target === RUNNING_BUILD) {
    if (stored) {
      await chrome.storage.local.remove(UPDATE_KEY);
      updateAllActiveTabBadges().catch(() => {});
    }
    return;
  }
  if (!stored || stored.target !== target) {
    await chrome.storage.local.set({
      [UPDATE_KEY]: { target, from: RUNNING_BUILD, reloadedAt: Date.now(), manual: false }
    });
    chrome.runtime.reload();
    return;
  }
  if (!stored.manual) {
    await chrome.storage.local.set({ [UPDATE_KEY]: { ...stored, manual: true } });
    updateAllActiveTabBadges().catch(() => {});
  }
}

async function manualUpdateNeeded() {
  try {
    const stored = (await chrome.storage.local.get(UPDATE_KEY))[UPDATE_KEY];
    return stored?.manual === true;
  } catch (_e) {
    return false;
  }
}

async function syncFromAppNow() {
  try {
    const configuration = await fetchConfiguration();
    const applied = await applyConfiguration(configuration);
    await checkForNewBuild(configuration).catch(() => {});
    return applied;
  } catch (error) {
    // Keep the last known PAC rather than switching to a direct proxy on an
    // API hiccup. A stale list can fail closed at the local proxy; a DIRECT
    // fallback could bypass the user's selected-domain policy.
    const cached = normalizeDomainConfiguration(await getStoredConfiguration());
    const cachedForwardingAllowed = cached.forwardingAllowed === true;
    const cachedBrowserRoutingEnabled = cached.browserRoutingEnabled === true || browserModeEnabled(cached);
    const cachedDomains = cachedBrowserRoutingEnabled ? cached.activeDomains : [];
    const cachedProxySubdomainDomains = cachedBrowserRoutingEnabled ? cached.activeSubdomainDomains : [];
    await setProxy({
      mode: "pac_script",
      pacScript: {
        data: pacForDomains(cachedDomains, cachedProxySubdomainDomains, cached.blockWhenDisconnected === true),
        mandatory: true
      }
    });
    await storeConfiguration({
      ...cached,
      routingMode: routingMode(cached),
      browserRoutingEnabled: cachedBrowserRoutingEnabled,
      forwardingAllowed: cachedForwardingAllowed,
      lastSyncSucceeded: false
    });
    return {
      ...cached,
      routingMode: routingMode(cached),
      browserRoutingEnabled: cachedBrowserRoutingEnabled,
      forwardingAllowed: cachedForwardingAllowed,
      lastSyncSucceeded: false,
      error: error.message
    };
  }
}

// All sync triggers share one queue. This prevents an alarm/startup sync that
// began before a pause mutation from finishing after the newer refresh sync.
function syncFromApp() {
  const next = syncChain.then(() => syncFromAppNow());
  syncChain = next.catch(() => {});
  return next;
}

let lastSyncTimestamp = 0;
function maybeSyncFromApp(throttleMs = 5000) {
  const now = Date.now();
  if (now - lastSyncTimestamp > throttleMs) {
    lastSyncTimestamp = now;
    return syncFromApp();
  }
  return Promise.resolve();
}

// Track navigation targets per tab (including in-flight and failed requests)
const tabTargets = new Map();

function isHttpOrHttps(url) {
  return typeof url === "string" && (url.startsWith("http://") || url.startsWith("https://"));
}

async function saveTabTarget(tabId, data) {
  tabTargets.set(tabId, data);
  if (chrome.storage && chrome.storage.session) {
    try {
      await chrome.storage.session.set({ ["tab_target_" + tabId]: data });
    } catch (_e) {}
  }
}

async function getTabTarget(tabId) {
  if (tabTargets.has(tabId)) {
    return tabTargets.get(tabId);
  }
  if (chrome.storage && chrome.storage.session) {
    try {
      const result = await chrome.storage.session.get("tab_target_" + tabId);
      return result["tab_target_" + tabId] || null;
    } catch (_e) {
      return null;
    }
  }
  return null;
}

async function removeTabTarget(tabId) {
  tabTargets.delete(tabId);
  if (chrome.storage && chrome.storage.session) {
    try {
      await chrome.storage.session.remove("tab_target_" + tabId);
    } catch (_e) {}
  }
}

if (chrome.webNavigation) {
  chrome.webNavigation.onBeforeNavigate.addListener((details) => {
    maybeSyncFromApp();
    if (details.frameId === 0 && isHttpOrHttps(details.url)) {
      saveTabTarget(details.tabId, {
        url: details.url,
        status: "pending",
        error: null,
        timestamp: Date.now()
      });
    }
  });

  chrome.webNavigation.onErrorOccurred.addListener((details) => {
    if (details.frameId === 0 && isHttpOrHttps(details.url)) {
      saveTabTarget(details.tabId, {
        url: details.url,
        status: "failed",
        error: details.error || "failed",
        timestamp: Date.now()
      });
    }
  });

  chrome.webNavigation.onCommitted.addListener((details) => {
    if (details.frameId === 0 && isHttpOrHttps(details.url)) {
      saveTabTarget(details.tabId, {
        url: details.url,
        status: "committed",
        error: null,
        timestamp: Date.now()
      });
    }
  });
}

if (chrome.tabs && chrome.tabs.onRemoved) {
  chrome.tabs.onRemoved.addListener((tabId) => {
    removeTabTarget(tabId);
  });
}

function hostMatchesDomain(host, candidate, subdomainDomains = []) {
  return host === candidate || host === "www." + candidate ||
    (subdomainDomains.includes(candidate) && host.endsWith("." + candidate));
}

function matchingDomain(hostname, domains = [], subdomainDomains = domains) {
  const host = (hostname || "").toLowerCase().replace(/\.$/, "");
  return domains.find((domain) => {
    const candidate = String(domain).toLowerCase().replace(/\.$/, "");
    return hostMatchesDomain(host, candidate, subdomainDomains);
  }) || null;
}

// Tabs without a routing badge show "UPD" while the extension needs a manual
// update; a listed site's routing state matters more.
async function setIdleBadge(tabId, title) {
  if (await manualUpdateNeeded()) {
    await chrome.action.setBadgeText({ text: "UPD", tabId });
    await chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId });
    if (chrome.action.setBadgeTextColor) {
      await chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
    }
    await chrome.action.setTitle({ title: "SemiVPN: extension update needed — open this popup", tabId });
    return;
  }
  await chrome.action.setBadgeText({ text: "", tabId });
  if (title) await chrome.action.setTitle({ title, tabId });
}

async function updateBadgeForTab(tabId, url) {
  if (!tabId || tabId < 0) return;

  try {
    if (!url) {
      const tab = await chrome.tabs.get(tabId);
      url = tab?.url || tab?.pendingUrl;
    }

    if (!url || !isHttpOrHttps(url)) {
      await setIdleBadge(tabId, "SemiVPN Domain Routing");
      return;
    }

    let hostname = null;
    try {
      hostname = new URL(url).hostname.toLowerCase().replace(/\.$/, "");
    } catch (_e) {
      await setIdleBadge(tabId, null);
      return;
    }

    const config = await getStoredConfiguration();
    const normalized = normalizeDomainConfiguration(config);
    const { domains, inactiveDomains, subdomainDomains, activeDomains, activeSubdomainDomains } = normalized;

    const matchedDomain = matchingDomain(hostname, domains, subdomainDomains);
    if (!matchedDomain) {
      // Direct site: clean toolbar icon with no badge
      await setIdleBadge(tabId, `SemiVPN: Direct (${hostname})`);
      return;
    }

    const isDomainActive = activeDomains.includes(matchedDomain) && hostMatchesDomain(hostname, matchedDomain, activeSubdomainDomains);
    const isPaused = !isDomainActive;
    const isBrowserMode = browserModeEnabled(config);
    const isForwardingAllowed = config.forwardingAllowed === true;

    if (isPaused) {
      await chrome.action.setBadgeText({ text: "OFF", tabId });
      await chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId }); // Amber
      if (chrome.action.setBadgeTextColor) {
        await chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
      }
      await chrome.action.setTitle({ title: `SemiVPN: Paused for ${hostname}`, tabId });
    } else if (isBrowserMode && isForwardingAllowed) {
      await chrome.action.setBadgeText({ text: "ON", tabId });
      await chrome.action.setBadgeBackgroundColor({ color: "#10b981", tabId }); // Emerald green
      if (chrome.action.setBadgeTextColor) {
        await chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
      }
      await chrome.action.setTitle({ title: `SemiVPN: Active (${hostname} -> VPN)`, tabId });
    } else if (isBrowserMode && config.blockWhenDisconnected === true) {
      // Fail-closed: the site is blocked until the VPN connects
      await chrome.action.setBadgeText({ text: "BLK", tabId });
      await chrome.action.setBadgeBackgroundColor({ color: "#dc2626", tabId }); // Red
      if (chrome.action.setBadgeTextColor) {
        await chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
      }
      await chrome.action.setTitle({ title: `SemiVPN: Blocked until the VPN connects (${hostname})`, tabId });
    } else {
      // In domain list, but VPN is disconnected
      await chrome.action.setBadgeText({ text: "DISC", tabId });
      await chrome.action.setBadgeBackgroundColor({ color: "#6b7280", tabId }); // Gray
      if (chrome.action.setBadgeTextColor) {
        await chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
      }
      await chrome.action.setTitle({ title: `SemiVPN: Disconnected (${hostname})`, tabId });
    }
  } catch (_e) {
    // If the tab was closed or does not exist, ignore gracefully
  }
}

async function updateAllActiveTabBadges() {
  try {
    const tabs = await chrome.tabs.query({ active: true });
    for (const tab of tabs) {
      if (tab.id) {
        updateBadgeForTab(tab.id, tab.url).catch(() => {});
      }
    }
  } catch (_e) {}
}

if (chrome.tabs) {
  if (chrome.tabs.onActivated) {
    chrome.tabs.onActivated.addListener((activeInfo) => {
      maybeSyncFromApp().catch(() => {});
      updateBadgeForTab(activeInfo.tabId).catch(() => {});
    });
  }

  if (chrome.tabs.onUpdated) {
    chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
      if (changeInfo.url || changeInfo.status === "complete") {
        updateBadgeForTab(tabId, tab?.url || changeInfo.url).catch(() => {});
      }
    });
  }
}

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create("semiVPN-sync", { periodInMinutes: 1 });
  syncFromApp();
});

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create("semiVPN-sync", { periodInMinutes: 1 });
  syncFromApp();
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "semiVPN-sync") syncFromApp();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "sync") {
    syncFromApp()
      .then((configuration) => sendResponse({ ok: true, configuration }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }
  if (message?.type === "getTabTarget") {
    getTabTarget(message.tabId)
      .then((target) => sendResponse({ ok: true, target }))
      .catch((error) => sendResponse({ ok: false, error: error.message }));
    return true;
  }
  return false;
});

// Prime the PAC after a service-worker restart. The cached configuration is
// enough to keep the policy fail-closed while the app API is being reached.
syncFromApp();
