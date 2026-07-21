#ifndef RTAtomics_h
#define RTAtomics_h

#include <stdint.h>

// Real-time-safe atomic Int64 load/store for the audio render thread.
// Swift's Synchronization module needs macOS 15 and swift-atomics is a
// third-party dependency, so these Clang builtins are the smallest
// Apple-frameworks-only way to publish ring-buffer positions across the
// net-queue/render-thread boundary. Storage is a plain Int64 allocated
// (8-byte aligned) on the Swift side.

static inline int64_t rt_atomic_load(const volatile int64_t *ptr) {
    return __atomic_load_n(ptr, __ATOMIC_ACQUIRE);
}

static inline void rt_atomic_store(volatile int64_t *ptr, int64_t value) {
    __atomic_store_n(ptr, value, __ATOMIC_RELEASE);
}

/// Returns the new value.
static inline int64_t rt_atomic_add(volatile int64_t *ptr, int64_t delta) {
    return __atomic_add_fetch(ptr, delta, __ATOMIC_ACQ_REL);
}

/// Returns the previous value.
static inline int64_t rt_atomic_exchange(volatile int64_t *ptr, int64_t value) {
    return __atomic_exchange_n(ptr, value, __ATOMIC_ACQ_REL);
}

#endif /* RTAtomics_h */
