const API_ENDPOINTS = [
  "http://[::1]:49281/v1",
  "http://127.0.0.1:49281/v1"
];

let isToggling = false;

const elements = {
  connection: document.getElementById("connection"),
  currentDomain: document.getElementById("current-domain"),
  currentSiteStatus: document.getElementById("current-site-status"),
  browserModeWarning: document.getElementById("browser-mode-warning"),
  browserModeWarningDetail: document.getElementById("browser-mode-warning-detail"),
  currentProxyState: document.getElementById("current-proxy-state"),
  currentToggle: document.getElementById("current-toggle"),
  currentStateIcon: document.getElementById("current-state-icon"),
  currentState: document.getElementById("current-state"),
  currentStateDetail: document.getElementById("current-state-detail"),
  addCurrent: document.getElementById("add-current"),
  removeCurrent: document.getElementById("remove-current"),
  manualAddForm: document.getElementById("manual-add-form"),
  manualDomainInput: document.getElementById("manual-domain-input"),
  manualAddBtn: document.getElementById("manual-add-btn"),
  manualAddError: document.getElementById("manual-add-error"),
  error: document.getElementById("error"),
  scopeDialog: document.getElementById("scope-dialog"),
  scopeDialogDomain: document.getElementById("scope-dialog-domain"),
  scopeAll: document.getElementById("scope-all"),
  scopeExact: document.getElementById("scope-exact"),
  scopeCancel: document.getElementById("scope-cancel"),
  deleteDialog: document.getElementById("delete-dialog"),
  deleteDialogDomain: document.getElementById("delete-dialog-domain"),
  deleteConfirm: document.getElementById("delete-confirm"),
  deleteCancel: document.getElementById("delete-cancel")
};

let currentHostname = null;
let currentDomainRule = null;
let currentDomainEnabled = false;
let activeTabId = null;
let activeTabTargetUrl = null;
let activeTabIsUnreachable = false;
let pendingAddHostname = null;
let pendingManualFullUrl = null;
let pendingDeleteDomain = null;

function showError(message) {
  elements.error.textContent = message;
  elements.error.hidden = !message;
}

async function api(path, options = {}) {
  let lastError = null;
  for (const base of API_ENDPOINTS) {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), options.timeout || 1500);
    try {
      const response = await fetch(base + path, {
        ...options,
        signal: controller.signal,
        headers: { "Content-Type": "application/json", ...(options.headers || {}) },
        cache: "no-store"
      });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error || "SemiVPN API returned " + response.status);
      return body;
    } catch (err) {
      lastError = err;
    } finally {
      clearTimeout(timeoutId);
    }
  }
  throw lastError || new Error("SemiVPN API unreachable");
}

function hostMatchesDomain(host, candidate, subdomainDomains) {
  return host === candidate || host === "www." + candidate ||
    (subdomainDomains.includes(candidate) && host.endsWith("." + candidate));
}

function matchingDomain(hostname, domains, subdomainDomains = domains) {
  const host = (hostname || "").toLowerCase().replace(/\.$/, "");
  return domains.find((domain) => {
    const candidate = String(domain).toLowerCase().replace(/\.$/, "");
    return hostMatchesDomain(host, candidate, subdomainDomains);
  }) || null;
}

function isIPv4(host) {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(host);
}

function parseDomainInput(raw) {
  let val = (raw || "").trim();
  if (!val) return null;
  let fullUrl = null;
  if (val.includes("://")) {
    fullUrl = val;
    try {
      val = new URL(val).hostname;
    } catch (_e) {
      return null;
    }
  } else {
    try {
      const parsed = new URL("http://" + val);
      val = parsed.hostname;
      if (raw.includes("/") || raw.includes(":")) {
        fullUrl = "http://" + raw;
      }
    } catch (_e) {
      val = val.split("/")[0].split(":")[0];
    }
  }
  val = val.toLowerCase().replace(/\.$/, "");
  return val ? { hostname: val, fullUrl } : null;
}

function getTabTargetFromWorker(tabId) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), 250);
    chrome.runtime.sendMessage({ type: "getTabTarget", tabId }, (response) => {
      clearTimeout(timer);
      if (chrome.runtime.lastError || !response?.ok) {
        resolve(null);
      } else {
        resolve(response.target || null);
      }
    });
  });
}

function getActiveTab() {
  return new Promise((resolve) => {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs && tabs[0]) return resolve(tabs[0]);
      chrome.tabs.query({ active: true, lastFocusedWindow: true }, (focusedTabs) => {
        resolve((focusedTabs && focusedTabs[0]) || null);
      });
    });
  });
}

async function detectActiveTabTarget() {
  const tab = await getActiveTab();
  if (!tab) {
    return { hostname: null, url: null, tabId: null, isUnreachable: false };
  }
  const tabId = tab.id;

  // 1. In-flight pending URL (instant resolution)
  if (tab.pendingUrl) {
    try {
      const parsed = new URL(tab.pendingUrl);
      if (["http:", "https:"].includes(parsed.protocol)) {
        return {
          hostname: parsed.hostname,
          url: tab.pendingUrl,
          tabId,
          isUnreachable: true
        };
      }
    } catch (_e) {}
  }

  // 2. Standard http/https URL (instant resolution, 0ms)
  if (tab.url) {
    try {
      const parsed = new URL(tab.url);
      if (["http:", "https:"].includes(parsed.protocol)) {
        return {
          hostname: parsed.hostname,
          url: tab.url,
          tabId,
          isUnreachable: false
        };
      }
    } catch (_e) {}
  }

  // 3. Fallback only for error pages (e.g. chrome-error://) or blank tabs
  try {
    const res = await getTabTargetFromWorker(tabId);
    if (res && res.url) {
      const parsed = new URL(res.url);
      if (["http:", "https:"].includes(parsed.protocol)) {
        return {
          hostname: parsed.hostname,
          url: res.url,
          tabId,
          isUnreachable: res.status === "failed" || res.status === "pending" || (tab.url && tab.url.startsWith("chrome-error://"))
        };
      }
    }
  } catch (_e) {}

  return { hostname: null, url: null, tabId, isUnreachable: false };
}

function vpnStatusLabel(status) {
  switch (status) {
    case "connected": return "Connected";
    case "connecting": return "Connecting…";
    case "reasserting": return "Reconnecting…";
    case "disconnecting": return "Disconnecting…";
    case "invalid": return "Not configured";
    case "disconnected": return "Disconnected";
    default: return "Unavailable";
  }
}

function routingMode(configuration) {
  if (typeof configuration.routingMode === "string") return configuration.routingMode;
  if (configuration.fullTunnel === true) return "all-apps";
  if (configuration.domainRouting === true) return "selected-apps-and-browser";
  return "selected-apps-only";
}

function browserModeEnabled(mode) {
  return ["selected-apps-and-browser", "browser-only"].includes(mode);
}

// inactiveDomains is the app-owned policy. Recompute active lists from it so
// a stale service-worker cache or inconsistent response cannot re-enable a
// domain when the popup is refreshed.
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
  return {
    ...configuration,
    domains,
    inactiveDomains,
    subdomainDomains,
    activeDomains: domains.filter((domain) => !inactiveDomains.includes(domain)),
    activeSubdomainDomains: subdomainDomains.filter((domain) => !inactiveDomains.includes(domain))
  };
}

function renderBrowserModeWarning(configuration) {
  const mode = routingMode(configuration);
  const browserEnabled = browserModeEnabled(mode);
  elements.browserModeWarning.hidden = browserEnabled || mode === "not-configured";
  if (browserEnabled || mode === "not-configured") return;
  switch (mode) {
    case "all-apps":
      elements.browserModeWarningDetail.textContent = "Browser domain routing is unavailable in All apps mode because Chrome is already covered by the full VPN tunnel. Choose Browser only or Selected apps + browser if you need domain-specific browser control.";
      break;
    case "selected-apps-only":
      elements.browserModeWarningDetail.textContent = "Browser domain routing is unavailable in Selected apps only mode. Choose Selected apps + browser or Browser only in SemiVPN.";
      break;
    default:
      elements.browserModeWarningDetail.textContent = "Choose a browser-enabled routing mode in SemiVPN to use domain routing.";
  }
}

function renderVPNStatus(configuration) {
  const unavailable = configuration.lastSyncSucceeded === false;
  const status = unavailable ? "unavailable" : (configuration.vpnStatus || "unknown");
  const label = unavailable ? "Unavailable" : vpnStatusLabel(status);
  const stateClass = status === "connected" && !unavailable
    ? "connected"
    : ["connecting", "reasserting", "disconnecting"].includes(status) ? "connecting" : "";

  elements.connection.textContent = "VPN: " + label;
  elements.connection.className = "status " + stateClass;
}

function renderCurrentSite(configuration, domains, subdomainDomains, activeDomains, activeSubdomainDomains) {
  if (!currentHostname) {
    currentDomainRule = null;
    currentDomainEnabled = false;
    elements.currentDomain.textContent = "No web page selected";
    if (elements.currentSiteStatus) elements.currentSiteStatus.hidden = true;
    elements.addCurrent.hidden = true;
    elements.currentProxyState.hidden = true;
    elements.removeCurrent.hidden = true;
    return;
  }

  elements.currentDomain.textContent = currentHostname;
  currentDomainRule = matchingDomain(currentHostname, domains, subdomainDomains);

  if (elements.currentSiteStatus) {
    if (activeTabIsUnreachable && !currentDomainRule) {
      elements.currentSiteStatus.textContent = "⚠️ Direct connection unreachable (firewalled / connecting)";
      elements.currentSiteStatus.className = "site-status-badge unreachable";
      elements.currentSiteStatus.hidden = false;
    } else {
      elements.currentSiteStatus.hidden = true;
    }
  }

  if (!currentDomainRule) {
    // An unlisted site has one action only: add it to the shared list.
    currentDomainEnabled = false;
    elements.addCurrent.hidden = false;
    elements.currentProxyState.hidden = true;
    elements.removeCurrent.hidden = true;
    return;
  }

  currentDomainEnabled = activeDomains.includes(currentDomainRule) && hostMatchesDomain(
    currentHostname.toLowerCase().replace(/\.$/, ""),
    currentDomainRule,
    activeSubdomainDomains
  );
  const mode = routingMode(configuration);
  const browserEnabled = browserModeEnabled(mode);
  elements.addCurrent.hidden = true;
  elements.currentProxyState.hidden = false;
  elements.removeCurrent.hidden = false;
  const paused = !currentDomainEnabled;
  const active = currentDomainEnabled && browserEnabled && configuration.forwardingAllowed === true && configuration.lastSyncSucceeded !== false;
  elements.currentState.textContent = paused ? "Paused" : active ? "Active" : "Passive";
  // The switch reflects the saved domain policy (the action is pause/resume),
  // while the state icon and text reflect effective routing and can be
  // Passive when the VPN is disconnected or the app API is unavailable.
  elements.currentStateIcon.textContent = active ? "●" : paused ? "⏸" : "○";
  elements.currentToggle.className = "route-toggle " + (currentDomainEnabled ? "on" : "off") + (isToggling ? " loading" : "");
  elements.currentToggle.disabled = isToggling;
  elements.currentToggle.setAttribute("aria-checked", String(currentDomainEnabled));
  elements.currentToggle.title = currentDomainEnabled
    ? "Pause routing for " + currentDomainRule
    : "Resume routing for " + currentDomainRule;
  elements.currentToggle.setAttribute("aria-label", elements.currentToggle.title);
  const removeLabel = "Remove " + currentDomainRule + " from SemiVPN";
  elements.removeCurrent.title = removeLabel;
  elements.removeCurrent.setAttribute("aria-label", removeLabel);
  elements.currentProxyState.className = "route-panel " + (active ? "active" : paused ? "paused" : "passive");
  if (!currentDomainEnabled) {
    elements.currentStateDetail.textContent = "Paused for this domain. Traffic stays direct.";
  } else if (configuration.lastSyncSucceeded === false) {
    elements.currentStateDetail.textContent = "SemiVPN is unavailable. Traffic stays direct until it reconnects.";
  } else if (mode === "all-apps") {
    elements.currentStateDetail.textContent = "All apps mode covers this site through the VPN; the browser proxy is not needed.";
  } else if (mode === "selected-apps-only") {
    elements.currentStateDetail.textContent = "Browser routing is not included in this mode. Traffic stays direct.";
  } else if (configuration.forwardingAllowed !== true) {
    elements.currentStateDetail.textContent = "Domain routing is enabled, but the VPN is not connected.";
  } else {
    elements.currentStateDetail.textContent = "This site is routed through SemiVPN.";
  }
}

function mergeDomainConfiguration(configuration, domainConfiguration) {
  return normalizeDomainConfiguration({ ...configuration, ...(domainConfiguration || {}) });
}

function render(configuration) {
  const normalized = normalizeDomainConfiguration(configuration);
  const domains = [...normalized.domains].sort();
  const subdomainDomains = normalized.subdomainDomains;
  const activeDomains = [...normalized.activeDomains].sort();
  const activeSubdomainDomains = normalized.activeSubdomainDomains;
  renderVPNStatus(normalized);
  renderBrowserModeWarning(normalized);
  renderCurrentSite(normalized, domains, subdomainDomains, activeDomains, activeSubdomainDomains);
}

async function refresh(domainConfiguration = null, preferredHostname = null) {
  const tabPromise = preferredHostname
    ? Promise.resolve({ hostname: preferredHostname, url: null, tabId: activeTabId, isUnreachable: false })
    : detectActiveTabTarget();
  const statusPromise = api("/status");

  try {
    const [tabTarget, configuration] = await Promise.all([tabPromise, statusPromise]);
    if (tabTarget) {
      if (tabTarget.hostname) currentHostname = tabTarget.hostname;
      if (tabTarget.tabId) activeTabId = tabTarget.tabId;
      activeTabTargetUrl = tabTarget.url;
      activeTabIsUnreachable = tabTarget.isUnreachable;
    }
    const merged = mergeDomainConfiguration(configuration, domainConfiguration);
    render(merged);
    showError("");
    chrome.storage.local.set({ semiVPNDomainConfiguration: merged });
  } catch (error) {
    const fallback = { domains: [], activeDomains: [], forwardingAllowed: false, vpnStatus: "unavailable", routingMode: "not-configured", lastSyncSucceeded: false };
    showError(error.message);
    const cached = await new Promise((resolve) => chrome.storage.local.get(["semiVPNDomainConfiguration"], resolve));
    if (cached?.semiVPNDomainConfiguration) {
      render(mergeDomainConfiguration({ ...cached.semiVPNDomainConfiguration, lastSyncSucceeded: false }, domainConfiguration));
    } else {
      render(mergeDomainConfiguration(fallback, domainConfiguration));
    }
  }
}

function routingDomainVariant(domain) {
  return domain.toLowerCase().replace(/^www\./, "");
}

function openScopeDialog(hostname) {
  pendingAddHostname = hostname;
  elements.scopeDialogDomain.textContent = routingDomainVariant(hostname);
  elements.scopeDialog.hidden = false;
  elements.scopeAll.focus();
}

function closeScopeDialog() {
  pendingAddHostname = null;
  pendingManualFullUrl = null;
  elements.scopeDialog.hidden = true;
  elements.addCurrent.focus();
}

function openDeleteDialog(domain) {
  pendingDeleteDomain = domain;
  elements.deleteDialogDomain.textContent = domain;
  elements.deleteDialog.hidden = false;
  elements.deleteConfirm.focus();
}

function closeDeleteDialog() {
  pendingDeleteDomain = null;
  elements.deleteDialog.hidden = true;
  elements.removeCurrent.focus();
}

async function confirmDeleteDomain() {
  const domain = pendingDeleteDomain;
  closeDeleteDialog();
  if (domain) await removeCurrentDomain(domain);
}

async function addPendingDomain(includeSubdomains) {
  const hostname = pendingAddHostname;
  const manualUrl = pendingManualFullUrl;
  pendingManualFullUrl = null;
  closeScopeDialog();
  if (!hostname) return;
  try {
    await addCurrentDomain(hostname, includeSubdomains, manualUrl);
    if (elements.manualDomainInput) elements.manualDomainInput.value = "";
    showError("");
  } catch (error) {
    showError(error.message);
  }
}

async function addCurrentDomain(domain, includeSubdomains, navigateUrl = null) {
  if (elements.addCurrent) elements.addCurrent.disabled = true;
  if (elements.manualAddBtn) elements.manualAddBtn.disabled = true;
  try {
    const domainConfiguration = await api("/domains", {
      method: "POST",
      body: JSON.stringify({ domain, includeSubdomains })
    });
    activeTabIsUnreachable = false;
    await refresh(domainConfiguration, domain.toLowerCase().replace(/\.$/, ""));

    // Reload or navigate active tab through VPN
    const reloadUrl = navigateUrl || (activeTabTargetUrl && (activeTabTargetUrl.includes(domain) || activeTabIsUnreachable) ? activeTabTargetUrl : null);
    if (activeTabId) {
      if (reloadUrl) {
        try {
          const p = chrome.tabs.update(activeTabId, { url: reloadUrl });
          if (p && typeof p.catch === "function") p.catch(() => {});
        } catch (_e) {}
      } else if (currentHostname && (currentHostname === domain || currentHostname.endsWith("." + domain))) {
        try {
          const p = chrome.tabs.reload(activeTabId);
          if (p && typeof p.catch === "function") p.catch(() => {});
        } catch (_e) {}
      }
    }

    if (elements.currentSiteStatus) {
      elements.currentSiteStatus.textContent = "✓ Added to SemiVPN — routing tab...";
      elements.currentSiteStatus.className = "site-status-badge reloading";
      elements.currentSiteStatus.hidden = false;
    }
  } finally {
    if (elements.addCurrent) elements.addCurrent.disabled = false;
    if (elements.manualAddBtn) elements.manualAddBtn.disabled = false;
  }
}

async function removeCurrentDomain(domain) {
  if (elements.removeCurrent) elements.removeCurrent.disabled = true;
  if (elements.deleteConfirm) elements.deleteConfirm.disabled = true;
  try {
    const domainConfiguration = await api("/domains?domain=" + encodeURIComponent(domain), { method: "DELETE" });
    await syncPAC();
    await refresh(domainConfiguration, currentHostname);
    showError("");
  } catch (error) {
    showError(error.message);
  } finally {
    if (elements.removeCurrent) elements.removeCurrent.disabled = false;
    if (elements.deleteConfirm) elements.deleteConfirm.disabled = false;
  }
}

async function toggleCurrentDomain(domain, enabled) {
  if (isToggling) return;
  isToggling = true;
  elements.currentToggle.disabled = true;
  elements.currentToggle.classList.add("loading");
  const previousDetail = elements.currentStateDetail ? elements.currentStateDetail.textContent : "";
  if (elements.currentStateDetail) {
    elements.currentStateDetail.textContent = enabled ? "Resuming routing for this domain…" : "Pausing routing for this domain…";
  }
  const minWait = new Promise((resolve) => setTimeout(resolve, 350));
  try {
    const domainPromise = api("/domains", {
      method: "PATCH",
      body: JSON.stringify({ domain, enabled })
    });
    const [domainConfiguration] = await Promise.all([domainPromise, minWait]);
    await syncPAC();
    await refresh(domainConfiguration, currentHostname);
    if (enabled && activeTabId && currentHostname && (currentHostname === domain || currentHostname.endsWith("." + domain))) {
      try {
        const p = chrome.tabs.reload(activeTabId);
        if (p && typeof p.catch === "function") p.catch(() => {});
      } catch (_e) {}
    }
    showError("");
  } catch (error) {
    await minWait;
    if (elements.currentStateDetail) {
      elements.currentStateDetail.textContent = previousDetail;
    }
    showError(error.message);
  } finally {
    isToggling = false;
    elements.currentToggle.disabled = false;
    elements.currentToggle.classList.remove("loading");
  }
}

function syncPAC() {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage({ type: "sync" }, (response) => resolve(response));
  });
}

elements.addCurrent.addEventListener("click", async () => {
  if (!currentHostname) return;
  if (isIPv4(currentHostname)) {
    try {
      await addCurrentDomain(currentHostname, false, activeTabTargetUrl);
      showError("");
    } catch (error) {
      showError(error.message);
    }
  } else {
    openScopeDialog(currentHostname);
  }
});

elements.scopeAll.addEventListener("click", () => addPendingDomain(true));
elements.scopeExact.addEventListener("click", () => addPendingDomain(false));
elements.scopeCancel.addEventListener("click", closeScopeDialog);
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !elements.scopeDialog.hidden) closeScopeDialog();
  if (event.key === "Escape" && !elements.deleteDialog.hidden) closeDeleteDialog();
});

if (elements.manualAddForm) {
  elements.manualAddForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    const raw = (elements.manualDomainInput.value || "").trim();
    if (elements.manualAddError) {
      elements.manualAddError.hidden = true;
      elements.manualAddError.textContent = "";
    }
    if (!raw) return;

    const parsed = parseDomainInput(raw);
    if (!parsed || !parsed.hostname) {
      if (elements.manualAddError) {
        elements.manualAddError.textContent = "Please enter a valid domain, IP address, or URL.";
        elements.manualAddError.hidden = false;
      }
      return;
    }

    const hostname = parsed.hostname;
    if (isIPv4(hostname)) {
      try {
        await addCurrentDomain(hostname, false, parsed.fullUrl);
        elements.manualDomainInput.value = "";
        showError("");
      } catch (err) {
        if (elements.manualAddError) {
          elements.manualAddError.textContent = err.message;
          elements.manualAddError.hidden = false;
        }
      }
    } else {
      pendingManualFullUrl = parsed.fullUrl;
      openScopeDialog(hostname);
    }
  });
}

elements.currentToggle.addEventListener("click", () => {
  if (currentDomainRule) toggleCurrentDomain(currentDomainRule, !currentDomainEnabled);
});

elements.removeCurrent.addEventListener("click", () => {
  if (currentDomainRule) openDeleteDialog(currentDomainRule);
});

elements.deleteConfirm.addEventListener("click", confirmDeleteDomain);
elements.deleteCancel.addEventListener("click", closeDeleteDialog);

const syncBtn = document.getElementById("sync");
if (syncBtn) {
  syncBtn.addEventListener("click", async () => {
    syncBtn.disabled = true;
    const prevText = syncBtn.textContent;
    syncBtn.textContent = "Refreshing…";
    try {
      await syncPAC();
      await refresh();
    } catch (_e) {}
    finally {
      syncBtn.disabled = false;
      syncBtn.textContent = prevText;
    }
  });
}

// Cache-first instant initialization (<5ms)
(async function init() {
  try {
    const [tabTarget, cached] = await Promise.all([
      detectActiveTabTarget(),
      new Promise((resolve) => chrome.storage.local.get(["semiVPNDomainConfiguration"], resolve))
    ]);
    if (tabTarget?.hostname) {
      currentHostname = tabTarget.hostname;
      activeTabId = tabTarget.tabId;
      activeTabTargetUrl = tabTarget.url;
      activeTabIsUnreachable = tabTarget.isUnreachable;
    }
    if (cached?.semiVPNDomainConfiguration) {
      render(cached.semiVPNDomainConfiguration);
    }
  } catch (_e) {}
  refresh();
})();
