# Engineering conventions

Use native APIs and preserve validation, ownership and recovery behavior.
Keep raw memory operations in the reviewed PageMemory and BoundedMemory boundaries.
The optional FreestandingGuest PAL is a separate unsafe RAM/ABI experiment; never
include its libc or stack-guard exports in package products or hosted applications.
Run the release tests and compile-fail consumers after changing ownership APIs.
Use Swift 6 language mode, two-space indentation and 100-column formatting.
Keep generated outputs, environment details and runtime data outside version control.
