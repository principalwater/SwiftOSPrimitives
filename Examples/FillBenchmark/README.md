# Native Swift volatile RAM fill comparison

This optional macOS fixture compares the guest PAL's aligned word stores with a
standalone byte-store Swift reference. Both keep the same extent guards, value
truncation, non-inlined entry and volatile-write contract. It is not a comparison
with libc memset, Rust, memory bandwidth or production network latency.

Build each source with Swift 6.4.1, Embedded/no-allocations, -O -wmo,
-strict-memory-safety -warnings-as-errors, the installed macOS SDK and an owned
module cache. Select exactly one fill implementation alongside main.swift:

```text
swiftc -enable-experimental-feature Embedded -no-allocations -O -wmo -parse-as-library -strict-memory-safety -warnings-as-errors -sdk /path/to/MacOSX27.0.sdk -module-cache-path /path/to/owned-cache ScalarFill.swift main.swift -o /path/to/scalar
swiftc -enable-experimental-feature Embedded -no-allocations -O -wmo -parse-as-library -strict-memory-safety -warnings-as-errors -sdk /path/to/MacOSX27.0.sdk -module-cache-path /path/to/owned-cache ../FreestandingGuest/MemoryFill.swift main.swift -o /path/to/word
```

Each run warms eight fills, then times 1024 fills of 64 KiB at offset one with
mach_absolute_time. A fixed InlineArray holds samples; sorting and decimal output
occur outside the timed calls. Three lines report p50/p95/p99 in nanoseconds, at
sorted sample indices 511/972/1013. Pointer identity, signed-value truncation and
complete byte extents are independently checked by FillProbe; this timing fixture
checks a changing byte and two outer sentinels. Do not disable validation for speed.

Three alternating runs on M2 Max/macOS 27.0.1, with nice 19 and the pinned 6.4.1
compiler, produced these measurements (microseconds):

| Repeat | Scalar p50 / p95 / p99 | Word p50 / p95 / p99 |
|---|---|---|
| 1 | 20.958 / 23.500 / 30.083 | 3.208 / 3.416 / 3.500 |
| 2 | 21.791 / 23.833 / 29.166 | 2.583 / 2.708 / 2.750 |
| 3 | 19.416 / 21.000 / 26.750 | 2.583 / 2.666 / 3.125 |

The paired p50 improvement ranges from 6.5 to 8.4 times. Whole-process retired
instructions were approximately 420–421 million versus 72–74 million, including
the common sorting and output work. `/usr/bin/time -l` maximum RSS was 1.69 MiB
for scalar and 1.67 MiB for word; that small difference is not a memory-saving
claim. CPU-time output is rounded to hundredths and is too coarse for a reliable
ratio. Startup/signing checks affect whole-process wall time and are outside the
per-fill timings. No weak VPS or real kernel measurements are claimed here.
