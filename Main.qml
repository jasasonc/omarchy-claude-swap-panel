import QtQuick
import Quickshell
import Quickshell.Io

// The display side of agent usage. All extraction lives behind
// omarchy-agent-usage-update, which writes one JSON record per agent into
// the usage directory, and bin/cswap-panel bridge, which adds one record per
// claude-swap account. This file never reads those files itself:
// `cswap-panel state` reads them without following symlinks and with size
// limits, and prints one JSON object.
//
// Every process starts through `cswap-panel run` (see LimitedProcess.qml),
// with a fixed absolute program path and a closed environment.
Item {
  id: root
  visible: false

  property var settings: ({})

  // ------------------------------------------------------ closed environment

  // Only these variables reach a process. A value that is not in a safe form
  // is left out, never set to null: for a null value Quickshell passes the
  // inherited value.
  readonly property var closedEnv: {
    var env = { "PATH": "/usr/bin:/bin", "OMARCHY_PATH": "/usr/share/omarchy", "LANG": "C.UTF-8" }
    var optional = {
      "HOME": absolutePath(Quickshell.env("HOME")),
      "XDG_RUNTIME_DIR": absolutePath(Quickshell.env("XDG_RUNTIME_DIR")),
      "WAYLAND_DISPLAY": plainToken(Quickshell.env("WAYLAND_DISPLAY")),
      "CLAUDE_CONFIG_DIR": absolutePath(Quickshell.env("CLAUDE_CONFIG_DIR")),
      "CODEX_HOME": absolutePath(Quickshell.env("CODEX_HOME"))
    }
    for (var key in optional) {
      if (optional[key] !== "") env[key] = optional[key]
    }
    return env
  }

  readonly property string home: closedEnv.HOME || ""

  function envText(value) {
    return value === null || value === undefined ? "" : String(value)
  }

  function absolutePath(value) {
    var text = envText(value)
    if (!/^\/[^\x00-\x1f\x7f]*$/.test(text)) return ""
    return /(^|\/)\.\.(\/|$)/.test(text) ? "" : text
  }

  function plainToken(value) {
    var text = envText(value)
    return /^[A-Za-z0-9._-]{1,64}$/.test(text) ? text : ""
  }

  // A record id, as `cswap-panel state` accepts it. Only such ids go on a
  // command line, so none can pass for an option.
  function validId(id) {
    return /^[a-z0-9][a-z0-9-]{0,79}$/.test(String(id))
  }

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value)
  }

  readonly property string panelScript: decodeURIComponent(String(Qt.resolvedUrl("bin/cswap-panel")).replace(/^file:\/\//, ""))
  readonly property var panelCommand: ["/usr/bin/python3", "-I", "-B", root.panelScript]

  // ------------------------------------------------------------------ state

  // claude-swap: the account Claude Code uses now. The built-in Claude Code
  // tab is named after it.
  property var cswapActive: null

  // Setup state from the bridge ("ok", "missing", "no-accounts" or "error").
  property var cswapStatus: ({})
  readonly property string cswapState: String(cswapStatus.state || "")

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0
  property bool statePending: false

  LimitedProcess {
    id: stateRun
    label: "cswap-panel state"
    panelScript: root.panelScript
    environment: root.closedEnv
    timeoutSec: 15
    maxOut: 4194304
    maxErr: 65536
    onDone: (ok, exitCode, output) => {
      // A failed read keeps the last good state.
      if (ok) root.applyState(output)
      if (root.statePending) {
        root.statePending = false
        root.readState()
      }
    }
  }

  function readState() {
    if (stateRun.running) root.statePending = true
    else stateRun.start(root.panelCommand.concat(["state"]))
  }

  function applyState(output) {
    var parsed
    try {
      parsed = JSON.parse(output)
    } catch (e) {
      console.warn("agents", "cswap-panel state: output is not JSON", e)
      return
    }
    if (!isObject(parsed)) return

    cswapStatus = isObject(parsed.status) ? parsed.status : ({})
    cswapActive = isObject(parsed.active) && parsed.active.name ? parsed.active : null

    var records = isObject(parsed.records) ? parsed.records : ({})
    var ids = Object.keys(records).filter(function(id) { return root.validId(id) && root.isObject(records[id]) }).sort()
    var list = []
    for (var i = 0; i < ids.length; i++) list.push({ agentId: ids[i], record: records[ids[i]] })
    agentIds = ids
    agents = list
    recordsChanged()
  }

  // The bridge writes status.json, also from the Add account terminal. A
  // change reads the state again. This view only watches: preload is off and
  // the content is never read here.
  FileView {
    path: root.home !== "" ? root.home + "/.local/state/cswap-omarchy/status.json" : ""
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readState()
  }

  // Tab name, slot number and email of the claude-swap account behind a record.
  function cswapFields(record) {
    var id = String(record.id || "")
    if (id === "claude" && root.cswapActive && root.cswapActive.name)
      return { name: String(root.cswapActive.name), number: Number(root.cswapActive.number) || 0,
               active: true, email: String(root.cswapActive.email || "") }
    if (id.indexOf("cswap-") === 0)
      return { name: String(record.name || ""), number: Number(record.cswapNumber) || 0,
               active: false, email: String(record.cswapEmail || "") }
    return { name: "", number: 0, active: false, email: "" }
  }

  // ----------------------------------------------------------------- bridge

  // `cswap-panel bridge` writes the claude-swap records and active.json. It
  // runs at start, on the claude-swap refresh interval, on each refresh, and
  // after a switch.
  property bool cswapBridgePending: false

  LimitedProcess {
    id: bridgeRun
    label: "cswap-panel bridge"
    panelScript: root.panelScript
    environment: root.closedEnv
    timeoutSec: 150
    maxOut: 65536
    maxErr: 65536
    onDone: (ok, exitCode, output) => {
      root.readState()
      if (root.cswapBridgePending) {
        root.cswapBridgePending = false
        root.runCswapBridge()
      }
    }
  }

  function runCswapBridge() {
    if (bridgeRun.running) root.cswapBridgePending = true
    else bridgeRun.start(root.panelCommand.concat(["bridge"]))
  }

  property int cswapRefreshIntervalSec: Math.min(3600, Math.max(60, Number(setting("cswapRefreshIntervalSec", 180))))

  Timer {
    interval: root.cswapRefreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runCswapBridge()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; a run that reaches the endpoint clears the flag.
  // Only the advising agents rerun, so an outage at one provider does not
  // put every other collector on a 30-second treadmill.
  property var retryAgentIds: []

  Timer {
    id: limitsRetry
    interval: 30000
    repeat: false
    onTriggered: root.runUpdate("limits", root.retryAgentIds)
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true && providerEnabled(String(record.id || "")))
        advising.push(String(record.id))
    }
    retryAgentIds = advising
    if (advising.length > 0) limitsRetry.restart()
    else limitsRetry.stop()
  }

  Component.onCompleted: readState()

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 900)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate("normal")
  }

  // Omarchy's own collectors, from /usr/bin. A forced run of all collectors
  // took about 4 s on the development machine; 300 s leaves room for a slow
  // network.
  LimitedProcess {
    id: updateRun
    label: "omarchy-agent-usage-update"
    panelScript: root.panelScript
    environment: root.closedEnv
    timeoutSec: 300
    maxOut: 65536
    maxErr: 262144
    onDone: (ok, exitCode, output) => {
      root.readState()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }
  }

  function updateCommand(kind, agentIds) {
    var command = ["/usr/bin/omarchy-agent-usage-update"]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false && validId(id)) command.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) {
        if (validId(agentIds[i])) command.push(String(agentIds[i]))
      }
    }
    return command
  }

  function runUpdate(kind, agentIds) {
    // A retry for named agents with no valid id left would run every collector.
    if (agentIds && agentIds.filter(function(id) { return root.validId(id) }).length === 0) return
    if (updateRun.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateRun.start(updateCommand(kind, agentIds))
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) {
    runUpdate(force === true ? "force" : "normal")
    runCswapBridge()
  }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() {
    readState()
    runUpdate("limits")
    runCswapBridge()
  }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers. With nothing to show, the
  // whole module collapses out of the bar rather than sitting there dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var result = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = String(record.id)
      if (!providerEnabled(id)) continue
      var display = displayProvider(record)
      if (providerHasData(display)) result.push(display)
    }
    // claude-swap tabs keep the account order, so key 1 is always account 1,
    // whichever account is active. Other tabs follow in their usual order.
    return result
      .map(function(p, i) { return { p: p, key: Number(p.cswapNumber) > 0 ? Number(p.cswapNumber) : 1000 + i } })
      .sort(function(a, b) { return a.key - b.key })
      .map(function(entry) { return entry.p })
  }

  function providerEnabled(id) {
    if (!settings || !settings.providers || !settings.providers[id]) return true
    return settings.providers[id].enabled !== false
  }

  // All-time keeps a quiet day from hiding an agent; today's counts admit a
  // machine whose only source is history.jsonl, which knows nothing older.
  function providerHasData(p) {
    return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
      || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
      || numberValue(p.todaySessions) > 0 || (p.limits && p.limits.length > 0)
      || !!p.balance
  }

  // A prepaid agent's credit ledger. Like rate limits, the balance is
  // per-account.
  function balanceValue(raw) {
    if (!raw || typeof raw !== "object") return null
    var remaining = Number(raw.remaining)
    var funded = Number(raw.funded)
    if (!isFinite(remaining) || remaining < 0) return null
    return {
      remaining: remaining,
      funded: isFinite(funded) && funded > 0 ? funded : 0,
      spent: Math.max(0, Number(raw.spent) || 0),
      currency: String(raw.currency || "USD"),
      estimated: raw.estimated === true
    }
  }

  function displayProvider(record) {
    var cswap = cswapFields(record)

    return {
      providerId: String(record.id),
      providerName: cswap.name || String(record.name || record.id),
      cswapNumber: cswap.number,
      cswapActive: cswap.active,
      cswapEmail: cswap.email,
      ready: record.ready === true,
      usageStatusText: String(record.usageStatusText || ""),
      authHelpText: String(record.authHelpText || ""),

      limits: Array.isArray(record.limits) ? record.limits : [],
      tierLabel: String(record.tierLabel || ""),
      balance: balanceValue(record.balance),

      todayPrompts: numberValue(record.todayPrompts),
      todaySessions: numberValue(record.todaySessions),
      todayTotalTokens: numberValue(record.todayTotalTokens),
      todayTokensByModel: record.todayTokensByModel || ({}),
      recentDays: record.recentDays || [],
      totalPrompts: numberValue(record.totalPrompts),
      totalSessions: numberValue(record.totalSessions),
      activeDays: numberValue(record.activeDays),
      modelUsage: record.modelUsage || ({}),
      hasLocalStats: record.hasLocalStats !== false,
      hasPromptStats: record.hasPromptStats !== false
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function numberValue(value) {
    var n = Number(value || 0)
    return isFinite(n) ? Math.round(n) : 0
  }

  // ---------------------------------------------------------------- format

  function formatTokenCount(n) {
    if (n === undefined || n === null) return "0"
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function modelWordCase(word) {
    if (word === "gpt") return "GPT"
    if (word === "deepseek") return "DeepSeek"
    return word.charAt(0).toUpperCase() + word.slice(1)
  }

  // Model ids arrive hyphenated with the version split across segments
  // (`claude-opus-4-8`, `gpt-5.6-sol`). Rejoin the numeric run into one
  // version and title-case the words around it.
  function friendlyModelName(id) {
    if (!id) return "Unknown"
    var name = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "")
    var parts = name.split("-")
    var words = []
    var version = []
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      if (part === "") continue
      if (/^\d/.test(part)) {
        version.push(part)
        continue
      }
      if (version.length > 0) {
        words.push(version.join("."))
        version = []
      }
      words.push(modelWordCase(part))
    }
    if (version.length > 0) words.push(version.join("."))
    return words.length > 0 ? words.join(" ") : "Unknown"
  }
}
