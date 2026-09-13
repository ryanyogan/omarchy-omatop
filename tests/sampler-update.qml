import QtQuick
import Quickshell
import "Model.js" as Model
Scope {
  id: root
  property int stage: 0
  property real oldPid: 0
  function check(ok, message) {
    if (!ok) { console.error("FAIL: " + message); Qt.quit(); throw new Error(message) }
  }
  Service { id: service }
  Timer {
    interval: 20; running: true; repeat: true
    onTriggered: {
      if (root.stage === 0 && service.samplerState === "running") {
        root.check(Model.olderSampler("", "1.2.2"), "legacy sampler needs an update")
        root.check(Model.olderSampler("1.2.1", "1.2.2"), "older version needs an update")
        root.check(!Model.olderSampler("1.2.2", "1.2.2"), "current version stays quiet")
        root.check(!Model.olderSampler("1.10.0", "1.2.2"), "newer numeric version stays quiet")
        root.check(service.samplerUpdateAvailable && service.canBuildSampler, "legacy tick surfaces the update action")
        root.oldPid = service.vitals.cpu.total
        service.buildSampler()
        service.buildSampler() // Duplicate activation must not spawn another build.
        root.check(service.samplerState === "building", "build progress is visible")
        service.ingest('{"v":1}') // Simulate buffered stdout from the stopped helper.
        root.check(service.samplerState === "building", "old ticks cannot overwrite progress")
        root.stage = 1
      } else if (root.stage === 1 && service.samplerState === "buildFailed") {
        root.check(service.buildLog.indexOf("intentional test failure") >= 0, "stderr is visible on failure")
        root.check(service.canBuildSampler, "failed build can be retried")
        service.ingest('{"v":1}')
        root.check(service.samplerState === "buildFailed", "old ticks cannot clear a failure")
        service.buildSampler()
        root.stage = 2
      } else if (root.stage === 2 && service.samplerState === "running") {
        root.check(service.samplerVersion === "1.2.2", "restarted helper reports the new version")
        root.check(!service.samplerUpdateAvailable && !service.canBuildSampler, "successful update clears the notice")
        root.check(service.vitals.cpu.total !== root.oldPid, "the old process was replaced")
        console.log("PASS: legacy/current/newer versions, duplicate activation, buffered ticks, failure/retry, helper replacement, cleared notice")
        Qt.quit()
      }
    }
  }
}
