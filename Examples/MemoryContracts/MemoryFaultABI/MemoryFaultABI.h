// Native ABI declarations only; all failure-injection behavior is implemented in Swift.
#include <sys/mman.h>
void *__real_mmap(void *, size_t, int, int, int, off_t);
int __real_munmap(void *, size_t);
