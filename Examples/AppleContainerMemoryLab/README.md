# Isolated Apple Container memory lab

Read [the contract and native evidence](../../Documentation/AppleContainerMemoryIntegration.md)
before running this optional package. It requires macOS/SDK27 and Swift6.4.1.
The portable root products have no Containerization dependency.

Build `container-memory-lab` with this package, release optimization, two jobs and
an absolute scratch path in a fresh owned workspace. Sign an owned copy with
`../VirtualizationBalloonLab/virtualization.entitlements`, then verify the signature.
Build `vz-balloon-guest` from that adjacent package with the matching static Linux
SDK and `--triple aarch64-swift-linux-musl`. Place its static AArch64 ELF at
`SHARE/probe`; SHARE must contain that single regular file, with no symlinks.

```text
container-memory-lab prepare NEW_PREPARED_DIR
container-memory-lab run PREPARED_DIR KERNEL_IMAGE SHARE NEW_RESULT_DIR policy
container-memory-lab run PREPARED_DIR KERNEL_IMAGE SHARE NEW_RESULT_DIR held
container-memory-lab run PREPARED_DIR KERNEL_IMAGE SHARE NEW_RESULT_DIR absent
container-memory-lab run PREPARED_DIR KERNEL_IMAGE SHARE NEW_RESULT_DIR ignored
container-memory-lab run PREPARED_DIR KERNEL_IMAGE SHARE NEW_RESULT_DIR cancel
```

Use absolute paths and a new result directory for every invocation. Preparation
downloads official vminit0.47.0 and Alpine3.22.1 into an explicitly owned ImageStore,
compares pinned digests, and creates private ext4 images. It does not start a VM.
Use the pinned default kernel described in the contract. Run only one VM at a time
under an external180s bounded process owner; preserve receipts, images and result JSON
before disposing any exclusively owned build cache. Do not attach production data.

The diagnostic exec has guest SYS_RAWIO/SYS_ADMIN capabilities. The workload's
stock capabilities remain intact, but this is a trusted synthetic lab, not an
untrusted-container sandbox qualification. The stock CLI/API service is neither
installed nor patched. `physicalReleasedBytes` intentionally remains unknown.
