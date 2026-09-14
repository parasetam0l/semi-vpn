const API_ENDPOINTS = [
  "http://127.0.0.1:49281/v1",
  "http://[::1]:49281/v1"
];
const PROXY_HOST = "127.0.0.1";
const PROXY_PORT = 49280;
const CACHE_KEY = "semiVPNDomainConfiguration";
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

function pacForDomains(domains, subdomainDomains = domains) {
  const serializedDomains = JSON.stringify(domains);
  const serializedSubdomainDomains = JSON.stringify(subdomainDomains);
  return "function FindProxyForURL(url, host) {" +
    " host = (host || '').toLowerCase().replace(/\\.$/, '');" +
    " var domains = " + serializedDomains + ";" +
    " var subdomainDomains = " + serializedSubdomainDomains + ";" +
    " for (var i = 0; i < domains.length; i++) {" +
    "   if (host === domains[i] || host === 'www.' + domains[i] ||" +
    "       (subdomainDomains.indexOf(domains[i]) !== -1 && dnsDomainIs(host, '.' + domains[i]))) {" +
    "     return 'PROXY [::1]:" + PROXY_PORT + "; PROXY " + PROXY_HOST + ":" + PROXY_PORT + "';" +
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
  const proxyAvailable = browserRoutingEnabled;
  const proxyDomains = proxyAvailable ? activeDomains : [];
  const proxySubdomainDomains = proxyAvailable ? activeSubdomainDomains : [];
  await setProxy({
    mode: "pac_script",
    pacScript: { data: pacForDomains(proxyDomains, proxySubdomainDomains), mandatory: true }
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
    revision: configuration.revision || 0,
    updatedAt: configuration.updatedAt || null,
    lastSyncSucceeded: true
  });
  updateAllActiveTabBadges();
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

async function fetchConfiguration() {
  const [status, domainConfiguration] = await Promise.all([
    apiFetch("/status"),
    apiFetch("/domains")
  ]);
  return normalizeDomainConfiguration({ ...status, ...domainConfiguration });
}

async function syncFromAppNow() {
  try {
    return await applyConfiguration(await fetchConfiguration());
  } catch (error) {
    // Keep the last known PAC rather than switching to a direct proxy on an
    // API hiccup. A stale list can fail closed at the local proxy; a DIRECT
    // fallback could bypass the user's selected-domain policy.
    const cached = normalizeDomainConfiguration(await getStoredConfiguration());
    const cachedBrowserRoutingEnabled = cached.browserRoutingEnabled === true || browserModeEnabled(cached);
    const cachedProxyAvailable = cachedBrowserRoutingEnabled;
    const cachedDomains = cachedProxyAvailable ? cached.activeDomains : [];
    const cachedProxySubdomainDomains = cachedProxyAvailable ? cached.activeSubdomainDomains : [];
    await setProxy({
      mode: "pac_script",
      pacScript: { data: pacForDomains(cachedDomains, cachedProxySubdomainDomains), mandatory: true }
    });
    await storeConfiguration({
      ...cached,
      routingMode: routingMode(cached),
      browserRoutingEnabled: cachedBrowserRoutingEnabled,
      lastSyncSucceeded: false
    });
    return {
      ...cached,
      routingMode: routingMode(cached),
      browserRoutingEnabled: cachedBrowserRoutingEnabled,
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

async function updateBadgeForTab(tabId, url) {
  if (!tabId || tabId < 0) return;

  if (!url) {
    try {
      const tab = await chrome.tabs.get(tabId);
      url = tab?.url || tab?.pendingUrl;
    } catch (_e) {
      return;
    }
  }

  if (!url || !isHttpOrHttps(url)) {
    chrome.action.setBadgeText({ text: "", tabId });
    chrome.action.setTitle({ title: "SemiVPN Domain Routing", tabId });
    return;
  }

  let hostname = null;
  try {
    hostname = new URL(url).hostname.toLowerCase().replace(/\.$/, "");
  } catch (_e) {
    chrome.action.setBadgeText({ text: "", tabId });
    return;
  }

  const config = await getStoredConfiguration();
  const normalized = normalizeDomainConfiguration(config);
  const { domains, inactiveDomains, subdomainDomains, activeDomains, activeSubdomainDomains } = normalized;

  const matchedDomain = matchingDomain(hostname, domains, subdomainDomains);
  if (!matchedDomain) {
    // Direct site: clean toolbar icon with no badge
    chrome.action.setBadgeText({ text: "", tabId });
    chrome.action.setTitle({ title: `SemiVPN: Direct (${hostname})`, tabId });
    return;
  }

  const isDomainActive = activeDomains.includes(matchedDomain) && hostMatchesDomain(hostname, matchedDomain, activeSubdomainDomains);
  const isPaused = !isDomainActive;
  const isBrowserMode = browserModeEnabled(config);
  const isForwardingAllowed = config.forwardingAllowed === true;

  if (isPaused) {
    chrome.action.setBadgeText({ text: "OFF", tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#f59e0b", tabId }); // Amber
    if (chrome.action.setBadgeTextColor) {
      chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
    }
    chrome.action.setTitle({ title: `SemiVPN: Paused for ${hostname}`, tabId });
  } else if (isBrowserMode && isForwardingAllowed) {
    chrome.action.setBadgeText({ text: "ON", tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#10b981", tabId }); // Emerald green
    if (chrome.action.setBadgeTextColor) {
      chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
    }
    chrome.action.setTitle({ title: `SemiVPN: Active (${hostname} -> VPN)`, tabId });
  } else {
    // In domain list, but VPN is disconnected
    chrome.action.setBadgeText({ text: "DISC", tabId });
    chrome.action.setBadgeBackgroundColor({ color: "#6b7280", tabId }); // Gray
    if (chrome.action.setBadgeTextColor) {
      chrome.action.setBadgeTextColor({ color: "#ffffff", tabId });
    }
    chrome.action.setTitle({ title: `SemiVPN: Disconnected (${hostname})`, tabId });
  }
}

async function updateAllActiveTabBadges() {
  try {
    const tabs = await chrome.tabs.query({ active: true });
    for (const tab of tabs) {
      if (tab.id) updateBadgeForTab(tab.id, tab.url);
    }
  } catch (_e) {}
}

if (chrome.tabs) {
  if (chrome.tabs.onActivated) {
    chrome.tabs.onActivated.addListener((activeInfo) => {
      updateBadgeForTab(activeInfo.tabId);
    });
  }

  if (chrome.tabs.onUpdated) {
    chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
      if (changeInfo.url || changeInfo.status === "complete") {
        updateBadgeForTab(tabId, tab?.url || changeInfo.url);
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
