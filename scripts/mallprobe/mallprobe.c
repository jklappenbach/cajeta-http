// LD_PRELOAD allocator probe. Counts LIVE malloc blocks and bytes, with a size
// histogram, so "is anything actually leaked" is answered directly rather than
// inferred from RSS. Valgrind cannot run this binary (unrecognised instruction
// from the znver5 codegen) and bpftrace needs root; this needs neither.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <malloc.h>
#include <signal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static void* (*real_malloc)(size_t);
static void* (*real_calloc)(size_t, size_t);
static void* (*real_realloc)(void*, size_t);
static void  (*real_free)(void*);

static _Atomic long live_count;
static _Atomic long live_bytes;
static _Atomic long alloc_calls;
static _Atomic long free_calls;

// 24 power-of-two buckets, index = floor(log2(usable size)).
static _Atomic long bucket[24];

// dlsym itself allocates, so early calls are served from a static arena.
static char boot[1 << 20];
static size_t boot_off;
static int in_init;

static int is_boot(void* p) {
    return (char*) p >= boot && (char*) p < boot + sizeof(boot);
}

static void init(void) {
    if (real_malloc) return;
    in_init = 1;
    real_malloc  = dlsym(RTLD_NEXT, "malloc");
    real_calloc  = dlsym(RTLD_NEXT, "calloc");
    real_realloc = dlsym(RTLD_NEXT, "realloc");
    real_free    = dlsym(RTLD_NEXT, "free");
    in_init = 0;
}

static void* boot_alloc(size_t n) {
    size_t a = (n + 15) & ~(size_t) 15;
    if (boot_off + a > sizeof(boot)) return NULL;
    void* p = boot + boot_off;
    boot_off += a;
    return p;
}

static int bucket_of(size_t s) {
    int b = 0;
    while (s > 1 && b < 23) { s >>= 1; b++; }
    return b;
}

static void note_alloc(void* p) {
    if (!p) return;
    size_t s = malloc_usable_size(p);
    __atomic_add_fetch(&live_count, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&live_bytes, (long) s, __ATOMIC_RELAXED);
    __atomic_add_fetch(&alloc_calls, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&bucket[bucket_of(s)], 1, __ATOMIC_RELAXED);
}

static void note_free(void* p) {
    if (!p) return;
    size_t s = malloc_usable_size(p);
    __atomic_sub_fetch(&live_count, 1, __ATOMIC_RELAXED);
    __atomic_sub_fetch(&live_bytes, (long) s, __ATOMIC_RELAXED);
    __atomic_add_fetch(&free_calls, 1, __ATOMIC_RELAXED);
    __atomic_sub_fetch(&bucket[bucket_of(s)], 1, __ATOMIC_RELAXED);
}

void* malloc(size_t n) {
    if (!real_malloc) { if (in_init) return boot_alloc(n); init(); }
    if (in_init) return boot_alloc(n);
    void* p = real_malloc(n);
    note_alloc(p);
    return p;
}

void* calloc(size_t n, size_t m) {
    if (!real_calloc) {
        if (in_init) { void* p = boot_alloc(n * m); if (p) memset(p, 0, n * m); return p; }
        init();
    }
    if (in_init) { void* p = boot_alloc(n * m); if (p) memset(p, 0, n * m); return p; }
    void* p = real_calloc(n, m);
    note_alloc(p);
    return p;
}

void* realloc(void* old, size_t n) {
    if (!real_realloc) init();
    if (is_boot(old)) { void* p = real_malloc(n); note_alloc(p); return p; }
    if (old) note_free(old);
    void* p = real_realloc(old, n);
    note_alloc(p);
    return p;
}

void free(void* p) {
    if (!p) return;
    if (is_boot(p)) return;
    if (!real_free) init();
    note_free(p);
    real_free(p);
}

static void dump(int sig) {
    (void) sig;
    char b[2048];
    int n = snprintf(b, sizeof(b),
        "[mall] liveBlocks=%ld liveBytes=%ld allocs=%ld frees=%ld\n",
        __atomic_load_n(&live_count, __ATOMIC_RELAXED),
        __atomic_load_n(&live_bytes, __ATOMIC_RELAXED),
        __atomic_load_n(&alloc_calls, __ATOMIC_RELAXED),
        __atomic_load_n(&free_calls, __ATOMIC_RELAXED));
    for (int i = 0; i < 24; i++) {
        long v = __atomic_load_n(&bucket[i], __ATOMIC_RELAXED);
        if (v > 0) n += snprintf(b + n, sizeof(b) - n, "        <=2^%d : %ld\n", i, v);
    }
    ssize_t w = write(2, b, n);
    (void) w;
}

// SIGUSR2: hand the allocator's free pages back to the OS. If RSS falls, the
// growth was retained free memory, not leaked blocks.
static void trim(int sig) {
    (void) sig;
    malloc_trim(0);
    const char* m = "[mall] malloc_trim done\n";
    ssize_t w = write(2, m, 24);
    (void) w;
}

__attribute__((constructor))
static void setup(void) {
    init();
    signal(SIGUSR1, dump);
    signal(SIGUSR2, trim);
}
