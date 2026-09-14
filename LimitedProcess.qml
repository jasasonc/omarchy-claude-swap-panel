import QtQuick
import Quickshell.Io

// One command started through `bin/cswap-panel run`. The runner gives the
// command its own process group, a deadline and live byte limits on stdout
// and stderr, and kills the whole group when the command ends. This side is
// a second layer: it starts the runner with a closed environment, counts the
// characters it gets, and stops the runner on overflow or when the runner
// itself runs too long.
Item {
  id: root
  visible: false

  // Absolute path of bin/cswap-panel, and the closed environment from Main.qml.
  property string panelScript: ""
  property var environment: ({})
  property string label: "cswap-panel"
  property int timeoutSec: 60
  property int maxOut: 65536
  property int maxErr: 65536

  // True from start() until done is emitted. Process.running changes only
  // when the process has started, so it is not enough to queue requests.
  readonly property bool running: busy
  property bool busy: false

  // ok is true only for a normal exit with code 0, inside the limits.
  signal done(bool ok, int exitCode, string output)

  property string outText: ""
  property string errText: ""
  property bool failed: false
  property bool exitSeen: true
  property bool resultOk: false
  property int resultCode: -1
  property string resultOutput: ""

  // target: the command for the runner, with an absolute argv[0].
  function start(target) {
    if (busy || process.running || panelScript.charAt(0) !== "/" || !target || target.length === 0
        || String(target[0]).charAt(0) !== "/")
      return false
    outText = ""
    errText = ""
    failed = false
    exitSeen = false
    busy = true
    watchdog.restart()
    killTimer.stop()
    process.command = ["/usr/bin/python3", "-I", "-B", panelScript, "run",
                       "--timeout", String(timeoutSec), "--max-out", String(maxOut),
                       "--max-err", String(maxErr), "--"].concat(target)
    process.running = true
    return true
  }

  function take(data, isOut) {
    if (failed) return
    var chunk = String(data)
    var current = isOut ? outText : errText
    if (current.length + chunk.length > (isOut ? maxOut : maxErr)) {
      stopAfterFailure((isOut ? "stdout" : "stderr") + " passed its limit")
      return
    }
    if (isOut) outText = current + chunk
    else errText = current + chunk
  }

  function stopAfterFailure(reason) {
    failed = true
    console.warn("agents", label + ":", reason + "; stopping it")
    // SIGTERM to the runner. The runner then stops its whole process group.
    process.running = false
  }

  function finish(ok, code) {
    watchdog.stop()
    killTimer.stop()
    resultOk = ok
    resultCode = code
    resultOutput = ok ? outText : ""
    outText = ""
    // Report after the Process has finished its own exit handling, so a
    // handler can start the next run at once.
    report.restart()
  }

  Process {
    id: process
    running: false
    clearEnvironment: true
    environment: root.environment

    stdout: SplitParser {
      splitMarker: ""
      onRead: data => root.take(data, true)
    }

    stderr: SplitParser {
      splitMarker: ""
      onRead: data => root.take(data, false)
    }

    onExited: (exitCode, exitStatus) => {
      root.exitSeen = true
      var text = root.errText.trim()
      if (text !== "") console.warn("agents", root.label + ":", text.slice(-2000))
      root.errText = ""
      root.finish(Number(exitStatus) === 0 && exitCode === 0 && !root.failed, exitCode)
    }

    // A runner that could not start sends no exited signal.
    onRunningChanged: {
      if (!running && !root.exitSeen) {
        root.exitSeen = true
        console.warn("agents", root.label + ": could not start")
        root.finish(false, -1)
      }
    }
  }

  // The runner stops the command at its deadline, 2 s grace included. This
  // fires only if the runner itself hangs: first SIGTERM, then SIGKILL, which
  // also makes the runner's keeper kill the process group.
  Timer {
    id: watchdog
    interval: (root.timeoutSec + 10) * 1000
    repeat: false
    onTriggered: {
      if (!process.running) {
        // It never started, so no exited signal comes.
        root.finish(false, -1)
        return
      }
      root.stopAfterFailure("ran past its deadline")
      killTimer.restart()
    }
  }

  Timer {
    id: killTimer
    interval: 5000
    repeat: false
    onTriggered: if (process.running) process.signal(9)
  }

  Timer {
    id: report
    interval: 0
    repeat: false
    onTriggered: {
      root.busy = false
      root.done(root.resultOk, root.resultCode, root.resultOutput)
    }
  }
}
