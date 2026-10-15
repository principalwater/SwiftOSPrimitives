# Disposable native VZ balloon lab

See [the experiment contract](../../Documentation/NativeVirtualizationBalloon.md).
The Mac host requires SDK/macOS27. The Linux probe uses the native system ABI;
the tiny Embedded Swift bootstrap mounts proc before the hosted runtime starts.

Library products do not include this example. No NIC/disk/share is attached.
The setter is request-only; actual PCI config counts are observed separately.
Host physical-release bytes remain unknown. Use a fresh owned result directory
for each mode, preserve evidence, and await stop before disposing the VM.


The `policy` mode uses `BoundedMemory.BalloonController` for a bounded free/load/free
experiment. It reserves the full256MiB cap, uses a192MiB allowance floor and32MiB
maximum step, and never infers additional host budget from a balloon completion.
Every target needs fresh requested/actual observations after setter delivery.
An error retires the controller and follows the same awaited owned-VM stop path.

```text
vz-balloon-lab KERNEL_IMAGE CURRENT_INITRAMFS NEW_RESULT_DIR policy
```

Use a freshly built matching guest protocol, not a historical archive fixture.
See [the Apple Container follow-up](../../Documentation/AppleContainerBallooning.md)
for the actual trace, source pins, limits and proposed integration hooks.
