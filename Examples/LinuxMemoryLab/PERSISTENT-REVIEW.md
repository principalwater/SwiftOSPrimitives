# G22 persistent-governance review

Official Claude Code, claude-opus-5-5, max effort, no tools/MCP, self-contained
generic source only. Original1800s deadline; public answer returned exit0 after
950.396s. The focused review covered RecentHistory and the governor, not the full
VMM. No security certification or comparative performance conclusion is implied.

Resolutions before v3 hardware qualification:

- Publish pending and an active request before the native setter. Record delivery
  before didApply, so a later failure retains conservative diagnostic state.
  The real setter either refuses before assignment or atomically changes its
  mutex-protected target; it does not wait for a vCPU or invoke the governor.
- Refuse fresh idle admission unless at least the original8s completion window
  remains in the caller lifetime. Rescue of already known work remains allowed;
  lifetime expiry does not extend the caller's watchdog.
- Do not send a passive command with less than50ms left before an absolute fence.
  Sleep to that fence and report its original timeout category. A sent operation
  that actually times out still closes the nonmultiplexed wire; no late reply can
  be reassigned. The3s normal probe and8s completion bounds remain unchanged.
- Arm an8s geometry fence for an unexplained native/guest capacity mismatch.
  Pending state and guest-capacity readiness are separately published.
- Capture native device state before stamping/checking the accepted observation.
  Check lifetime, freshness and completion fences after all input reads.
- Clip sleeps to pending geometry/lifetime deadlines. Failure and running=false
  are published together; the caller still joins the task before VM destruction.
- Validate trusted clock/boot arithmetic assumptions at construction. Product
  configuration remains a separate untrusted-input admission boundary.

Stop means no new idle admission. A rescue may still change an already pending
target, including while Linux online accounting lags. Each latest issued request
keeps its own original8s fence; a rescue does not silently enlarge that request's
budget. The guest kernel pins memory_hotplug.memmap_on_memory=0, as qualified.

Additional live test: continuous-expire uses an explicit2s caller lifetime,
requires zero resize requests, coherent final capacity, intact data and a usable
wire after the expected deadline. The hardware qualification report records its
actual outcome; implementing this profile alone is not evidence that it passed.

The underlying research VMM still has its explicit120s/3million-exit guard and
console/write admission caps. A future persistent-host slice must replace lifetime
quotas with caller-owned watchdogs and bounded/rate-aware resource policy before
this is an unattended production service.
