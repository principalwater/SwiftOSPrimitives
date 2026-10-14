# Memory ownership contracts

Finite native probes for stable typed storage, owned page backing and failure recovery.
They open no network listener, change no system configuration and touch only their mappings.

```text
swift run --package-path Examples/MemoryContracts -c release memory-contracts
swift run --package-path Examples/MemoryContracts -c release memory-faults
```

The second executable is Linux-only. Its native linker wraps `mmap`/`munmap` with
Swift functions in this executable, never in library products. The header supplies
ABI declarations only, no C implementation. It injects one mapping refusal, a null
mapping result without actually mapping address zero, constructor failure and one
unmap refusal. Public owner methods must preserve error identity, retire value access,
destroy exactly once and retain backing for retry. Null-result cleanup gets a final
fallback attempt. This is deterministic failure injection, not an induced host OOM.

The first executable places/destroys256 noncopyable values, checks their actual slot
addresses across owner moves, composes existing ScratchArena/FrameLedger with real
anonymous backing, and tests a2MiB touch/discard/reset cycle. It emits an independent
digest, process CPU/wall time, self RSS and mincore residency. It is a contract probe,
not a request-latency distribution or a language-wide performance ranking.

To cross-build on macOS with an installed, verified Swift6.4.1 staticLinux SDK:

```text
swift build --package-path Examples/MemoryContracts --scratch-path /owned/build/linux \
  --swift-sdks-path /verified/swift-sdks --swift-sdk x86_64-swift-linux-musl \
  -c release --jobs 2 -Xswiftc -warnings-as-errors
```

Run cloud probes only on an explicitly authorized node after checking production roles
and service health. Bound CPU, RAM, tasks, swap and elapsed time using native cgroups.
Do not compile on a production VPS, induce host-wide memory pressure, load modules or
change network/service configuration. Cgroup throttling changes wall time; report CPU
separately. A standby routing role does not mean an idle host with no real users.
