# Disposable native Swift QMP lab

See [HostBalloon](../../Documentation/HostBalloon.md) for contracts and reproduction.
The executable requires four arguments: verified QEMU path, audited host-balloon guest ELF,
new private evidence directory and mode (`cycles`, `absent`, `cancel-inflated`, `wrong-target`).

It creates only an owned64MiB, one-CPU TCG guest, without NICs, disks or passthrough devices.
Output retains exact serial/QEMU diagnostics, invocation and logical-size observations.
Physical release stays unknown. No existing VM/process/configuration is controlled.
