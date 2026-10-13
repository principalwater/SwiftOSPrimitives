# NIO resource lifecycle example

A separately built diagnostic, not a dependency of PageMemory. Pinned SwiftNIO2.103 provides one event loop and local128-byte TCP echo. The executable validates21 successful connections,10 intentionally unresponsive peers with50ms deadlines, exactly-once completion and equal open-descriptor counts after joined shutdown.

```text
swift run --package-path Examples/NIOResourceLab -c release
```

Sockets bind only to127.0.0.1 on an ephemeral port. The diagnostic changes no OS/network configuration and reads only its own memory/fd counters. Use a private network namespace for a co-located Linux run.

This is lifecycle evidence, not a Rust/Tokio comparison, a TLS/SSH benchmark, congestion/failover acceptance or multi-day soak. It also does not prove large queued-write backpressure; each session permits one128-byte message in flight.
