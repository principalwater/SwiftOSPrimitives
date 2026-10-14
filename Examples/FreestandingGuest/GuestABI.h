void guest_exit(void) __attribute__((noreturn));
void guest_corrupt_guard(void *escaped);
void guest_test_trap(void) __attribute__((noreturn));
void guest_test_other_trap(void) __attribute__((noreturn));
