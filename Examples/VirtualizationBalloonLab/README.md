# Disposable native VZ balloon lab

See [the experiment contract](../../Documentation/NativeVirtualizationBalloon.md).
The Mac host requires SDK/macOS27. The Linux probe uses the native system ABI;
the tiny Embedded Swift bootstrap mounts proc before the hosted runtime starts.

Library products do not include this example. No NIC/disk/share is attached.
The setter is request-only; actual PCI config counts are observed separately.
Host physical-release bytes remain unknown. Use a fresh owned result directory
for each mode, preserve evidence, and await stop before disposing the VM.
