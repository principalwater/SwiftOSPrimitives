# G21 independent review and resolution

Official Claude Code2.1.296, model claude-opus-5-5, max effort requested/active,
zero tools/MCP, self-contained generic source brief. A public result arrived with
exit0 after487.076seconds, below the original900second deadline. Invocation, public
answer and outcome are retained outside Git. This focused review is not certification
of the complete hypervisor or library.

- Capacity checks after native side effects: fixed. Sample capacity is checked before
  sending OBS; request capacity before the native setter. No await intervenes between
  request admission, setter, delivery fence and recording. Only the run owner appends
  records; stop changes only a flag. Budget exhaustion terminates this finite VM.
- Native critical pressure: accept value4 alongside normal1/warning2. Warning and
  critical map to hostUnderPressure. A guest/host pressure conflict remains terminal
  and the caller tears down this VM. Global critical pressure was not induced.
- Short remaining deadlines can poison the shared wire: intentional fail-closed scope.
  After a sent command times out, its late response cannot safely be assigned to another
  caller. The error retires governance and ends this finite VM. Queue-only cancellation
  or deadline does not poison its current owner. A subsequent4vCPU trial exposed passive
  deadline expenditure behind HOLD. Passive observation now uses non-waiting admission;
  a real transport test verifies skip, unchanged sequence and subsequent successful poll.
- Calling start twice/before-ready operations closes the session: intentional lifecycle
  misuse failure for this internal type. Caller awaits start before creating governor.
- Conditional issue-after-completion on graceful stop: existing BalloonController pending
  branch clears completion and returns nil, without issuing a new request. Stop drains
  an already known request; exceptional cancellation joins before VM destruction.
- Clock origins: one caller passes the same began Instant to transport and governor.
  Clock origin and minimum target are admitted by this caller and controller, not public
  untrusted input. Workload owns task handles and joins on success and error paths;
  neither driver nor transport retains an owner task.

Independent query review used clickhouse-best-practices rules query-join-choose-algorithm
and agent-query-safety. The bounded100K-row hash join intentionally holds measurable RAM;
scan, result, memory and time limits remain unchanged. Initial continuous trial failed
on ClickHouse's3second per-block sleepEachRow limit. A32768row max_block_size bounds each
block's artificial wait while preserving total6second load and8second query ceiling.
The6second profile still exceeded the fixed8second query ceiling on4vCPU. Final trials
reuse the exact canonical G20 query (4second dwell, no block override), without reducing
rows, required active memory, canary coverage or any time/memory limit. Every original
failed VM outcome and signed artifact/source snapshot remains retained.
