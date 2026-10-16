# Native Swift full-byte canary optimization

The previous scalar loops could exceed a finite guest command deadline under memory pressure.
The deadline, allocation size, byte coverage and corruption checks remain unchanged. The optional
lab's MemoryCanary target replaces only the main64MiB and pressure320MiB pattern operations.
Per-vCPU worker canaries and native memory-ownership safeguards are unchanged.

MemoryCanary builds one256byte InlineArray tile. Filling copies bounded chunks inside a borrowed
MutableSpan; checking compares complete unaligned UInt64 words against the same pattern, followed
by every remaining byte. The scalar pattern repeats modulo256, so this preserves all previous
expected bytes. Raw pointers remain confined to their borrowed span closures. No proportional
scratch allocation, custom C/Rust implementation, unchecked optimization flag or weaker check
is used. Zero length performs no pointer access; each word is entirely inside the input span.

Independent scalar golden tests cover two patterns,16offsets, lengths0/1/7/8/9/255/256/257/1025,
and untouched prefix/suffix sentinels. Corruption at byte/word/tile/final-tail boundaries is rejected.
Swift6.4.1 compiler lifetime diagnostics were resolved without disabling warnings-as-errors.

## Host microbenchmark

Mac Studio M2Max, macOS27.0.1, Swift6.4.1 release, nice19, one64MiB PageRegion. An untimed full
prefill makes pages resident before measurement. Four phases use scalar/batched/batched/scalar
order, each performing two full fill+check rounds on the same region. Raw log and original native
outcome are retained outside Git.

| Implementation | Phase1 | Phase2 | Median |
| --- | ---: | ---: | ---: |
| Scalar |88.654500ms|80.437000ms|84.545750ms|
| Batched |7.161584ms|7.147084ms|7.154334ms|

This is about11.8times faster for this canary operation. Whole process user/system CPU was
0.185306/0.009385seconds, maximum RSS72990720bytes including the64MiB region. This is a small
synthetic comparison, not a Rust comparison, production throughput guarantee or VM-wide speedup.
The actual Linux/ClickHouse qualification is recorded separately after runtime validation.
