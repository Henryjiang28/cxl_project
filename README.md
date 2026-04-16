# Cache-Aware and Color-Preserving Page Migration for CXL Tiered Memory

**Authors:** Aubhro Sengupta, Henry Jiang

---

## Overview

This project implements and evaluates a cache-aware page migration policy for CXL-based tiered memory systems. Modern servers increasingly attach CXL (Compute Express Link) memory as a large but slower second tier. The OS migrates cold pages to CXL to relieve DRAM pressure — but existing policies blindly ignore where pages sit in the last-level cache (LLC), causing two problems:

1. **Cache-unaware migration**: hot LLC pages get evicted to CXL, forcing expensive repeated remote accesses.
2. **Cache color disruption**: migrating a page changes its physical frame number, altering its LLC set mapping and potentially introducing new cache conflicts.

Our system addresses both by (a) using LLC activity as a migration gate and (b) selecting destination frames whose cache color matches the source.

---

## Repository Structure

```
cxl_project/
├── Makefile
├── README.md
├── bench/
│   └── latency_bench.c       # Microbenchmark: measure DRAM vs CXL-emulated node latency
└── migrate/
    ├── baseline_migrate.c    # Baseline cold-page migration using move_pages()
    └── color_migrate.c       # Page-color-aware migration with per-color CXL free lists
```

---

## Environment Setup (Week 2 Milestone)

### Why NUMA emulation?

Real CXL hardware is not yet widely available. The standard research approach is to emulate CXL by using a remote NUMA node with artificially higher access latency. Linux's `numactl` and `libnuma` provide the userspace API needed to bind memory to specific nodes and migrate pages between them — no kernel patches or root access required.

### Machine topology

The target machine has **4 NUMA nodes**. We use:

| NUMA Node | Role | NUMA Distance from Node 0 |
|-----------|------|--------------------------|
| node 0 | **DRAM** (local, fast) | 10 (self) |
| node 2 | **CXL-emulated** (remote, slow) | 31 |

Node 2 is chosen because it has the highest topological distance from node 0 (31 vs. 21 for nodes 1 and 3), giving the largest natural latency gap.

### Measured latency (verified on this machine)

| Node | Role | Measured latency |
|------|------|-----------------|
| node 0 | DRAM | ~22 cycles/access |
| node 2 | CXL-emu | ~52 cycles/access |
| Ratio | — | **~2.35×** |

This 2.35× overhead falls squarely within the expected CXL latency range (typically 2–3× DRAM), making the emulation realistic without any latency injection.

> **Note on `tc netem`:** We do not use traffic-control-based latency injection because it requires root privileges. The natural NUMA distance provides sufficient and realistic latency differentiation.

---

## Building

```bash
cd ~/cxl_project
make all
```

Requires: `gcc`, `libnuma` (`/usr/include/numa.h`, `/usr/lib64/libnuma.so`).

---

## Components

### 1. `bench/latency_bench.c` — Latency Verification

**What it does:** Allocates a 256 MB buffer (larger than LLC) on each NUMA node and measures the average random-access latency in CPU cycles using `rdtsc`.

**Why 256 MB?** The buffer must exceed the LLC size so that accesses are guaranteed to miss the cache and actually reach DRAM or the remote NUMA node. This isolates memory-tier latency from cache effects.

**How to run:**
```bash
make run-latency
# or manually:
numactl --cpunodebind=0 --membind=0 ./bench/latency_bench
```

**Expected output:**
```
node 0 (DRAM):    22.x cycles/access
node 2 (CXL-emu): 52.x cycles/access
```

---

### 2. `migrate/baseline_migrate.c` — Baseline Page Migration

**What it does:** Demonstrates the core page migration primitive that all later policies will build on.

1. Allocates `N_PAGES` (1024 × 4 KB = 4 MB) on node 0 (DRAM).
2. Touches every page to force physical allocation.
3. Calls `move_pages()` to migrate all pages to node 2 (CXL).
4. Queries node membership before and after to verify correctness.
5. Migrates pages back to node 0 to demonstrate bidirectional movement.

**Why `move_pages()` and not `mbind()`?**
- `mbind()` sets a policy for future allocations in a virtual address range; it does not move already-allocated physical pages.
- `move_pages()` (Linux syscall 317) actually relocates existing physical frames to a target NUMA node — this is the primitive the OS page migration daemon uses internally.

**How to run:**
```bash
make run-migrate
# or manually:
numactl --cpunodebind=0 ./migrate/baseline_migrate
```

**Expected output:**
```
[Before migration] pages on node0=1024 node1=0 node2=0 node3=0 err=0
[After  migration] pages on node0=0    node1=0 node2=1024 node3=0 err=0
Migration success: 1024/1024 pages (100.0%)
[After  migration back] pages on node0=1024 ...
```

---

### 3. `migrate/color_migrate.c` — Page-Color-Aware Migration

**What it does:** Extends baseline migration with cache-color preservation. Instead of letting the OS place migrated pages at arbitrary physical frames on the CXL node, it pre-selects destination frames whose LLC cache color matches the source.

**Color computation:**
```
color = pfn % num_cache_colors
num_cache_colors = cache_sets / (PAGE_SIZE / cache_line_size)
```
LLC geometry is read from `/sys/devices/system/cpu/cpu0/cache/index3/`. With a 2048-set, 64 B-line LLC: `num_cache_colors = 2048 / 64 = 32`.

**Algorithm:**

1. Allocate source pages on node 0 (DRAM); fault them in.
2. Over-allocate a CXL pool (`OVERSAMPLE × N_PAGES` = 8192 pages) on node 2; fault them in.
3. Read physical frame numbers from `/proc/self/pagemap`; fall back to virtual-address coloring if running without root.
4. Build per-color free lists from the CXL pool (the userspace analog of per-color buddy lists in the kernel allocator).
5. For each source page: compute its color, pop a same-color CXL slot, `memcpy` the data to that slot. Falls back to any available slot if a color bin is exhausted.
6. Report color-match rate, NUMA placement (via `move_pages()`), per-color histogram, and data integrity.

**How to run:**
```bash
make run-color-migrate           # virtual-address coloring (no root needed)
make run-color-migrate-root      # physical PFN coloring (accurate, requires sudo)
```

**Expected output (as root):**
```
[LLC] detected  sets=2048  line=64B  sets_per_page=64  colors=32
[pool] CXL pool classified: 8192 physical, 0 virtual coloring
[pool] 32/32 colors populated  min=245 max=265 pages/color
[migration] same-color=1024  fallback=0  dropped=0  total=1024
[result] pages migrated: 1024/1024  color-preserved: 1024/1024 (100.0%)
[integrity] data corruption: 0/1024 pages
```

**Limitation vs. kernel implementation:** `move_pages()` does not accept a specific target physical frame; it migrates to a node. The userspace workaround is to pre-allocate the CXL pool and copy data to the color-matched frame. A kernel implementation would pass a color-aware allocator function to `migrate_pages()` directly — see the Kernel Modifications section below.

---

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Build all binaries |
| `make clean` | Remove binaries |
| `make check` | Print NUMA topology and node distances |
| `make run-latency` | Run latency benchmark (CPU bound to node 0) |
| `make run-migrate` | Run baseline migration test |
| `make run-color-migrate` | Run color-aware migration (virtual-address coloring) |
| `make run-color-migrate-root` | Run color-aware migration (physical PFN coloring, requires sudo) |

---

## Project Milestones

| Week | Goal | Status |
|------|------|--------|
| 2 | NUMA CXL emulation setup; baseline `move_pages()` migration; verify latency difference | **Done** |
| 4 | Cache color extractor; per-color free lists; color-preserving migration (userspace) | **Done** |
| 6 | Hotness tracker; kernel-level color-aware allocator; full evaluation vs. baselines; final poster | Planned |

---

## Next Steps (Week 6)

- **Hotness Tracker:** Scan `/proc/PID/pagemap` + accessed bits (or use `perf` sampling) to classify pages as hot/cold and gate migration on coldness.
- **Evaluation:** Compare color-aware vs. baseline migration on a cache-sensitive workload (e.g., hash-table or matrix multiply); measure LLC miss rate via `perf stat -e LLC-load-misses`.
- **Kernel prototype:** Implement per-color free lists and a color-aware `alloc_migration_target` — see Kernel Modifications below.

---

## Kernel Modifications Required

The userspace implementation in `color_migrate.c` demonstrates the algorithm but cannot control which physical frame `move_pages()` assigns on the target node. A production-quality implementation requires the following kernel changes.

### 1. Buddy Allocator — Per-Color Free Lists

**Files:** `mm/page_alloc.c`, `include/linux/mmzone.h`

Extend `struct zone` with a free list per cache color:

```c
/* include/linux/mmzone.h */
struct zone {
    /* ... existing fields ... */
    struct list_head  color_free_list[MAX_CACHE_COLORS];
    unsigned long     color_nr_free[MAX_CACHE_COLORS];
};
```

On page free (`__free_one_page`), compute the color and push onto `color_free_list[color]` for CXL zones. Color in the kernel is trivial:

```c
static inline int page_cache_color(struct page *page)
{
    return (int)(page_to_pfn(page) % num_cache_colors);
}
```

Keep the normal buddy path untouched for DRAM zones; color lists are a parallel structure used only during CXL allocation to avoid touching the performance-critical fast path.

### 2. Color-Aware Allocation Path

**File:** `mm/page_alloc.c`

Add a new allocator entry point:

```c
struct page *alloc_pages_node_color(int nid, gfp_t gfp,
                                    unsigned int order, int target_color);
```

Inside `get_page_from_freelist()`, when a color is requested, scan `zone->color_free_list[target_color]` first, then fall back to any free frame if the bin is empty.

### 3. Migration Target Selection Hook

**File:** `mm/migrate.c`

`migrate_pages()` accepts an `alloc_fn` pointer. Replace the default with a color-aware version:

```c
struct page *alloc_migration_target_colored(struct page *src_page,
                                            unsigned long private)
{
    int src_color  = page_cache_color(src_page);
    int target_nid = (int)private;
    return alloc_pages_node_color(target_nid, GFP_HIGHUSER_MOVABLE,
                                  0, src_color);
}
```

No deeper changes to the migration engine are needed — only the allocator callback changes.

### 4. LLC Topology — Computing `num_colors`

**Files:** `arch/x86/kernel/cpu/cacheinfo.c`, `drivers/base/cacheinfo.c`

The kernel already populates `struct cacheinfo` at boot. Compute once during `mm_init()`:

```c
static unsigned int compute_num_cache_colors(void)
{
    struct cpu_cacheinfo *ci = get_cpu_cacheinfo(0);
    /* last entry is the LLC */
    struct cacheinfo *llc = &ci->info_list[ci->num_levels - 1];
    unsigned int sets_per_page = PAGE_SIZE / llc->coherency_line_size;
    return llc->number_of_sets / sets_per_page;
}
```

This is the same formula as the userspace version but reads from in-kernel structures.

### 5. CXL Node Identification

**Files:** `drivers/acpi/hmat/hmat.c`, `mm/mempolicy.c`

The HMAT table distinguishes memory types by initiator-target bandwidth/latency pairs. Add a `nodemask_t cxl_node_mask` populated during `acpi_hmat_init()`. The migration policy then gates color-preserving behavior on `node_isset(target_nid, cxl_node_mask)`.

### 6. CXL Memory Online — Pre-classifying Pages

**File:** `mm/memory_hotplug.c`

When CXL memory comes online (`online_pages()`), walk the new PFN range and pre-populate `color_free_list[]` — the kernel analog of `build_color_lists()` in `color_migrate.c`:

```c
for (pfn = start_pfn; pfn < end_pfn; pfn++) {
    struct page *page = pfn_to_page(pfn);
    int color = (int)(pfn % num_cache_colors);
    list_add(&page->lru, &zone->color_free_list[color]);
    zone->color_nr_free[color]++;
}
```

### 7. Cold-Page Detection for Automatic Demotion

**File:** `mm/vmscan.c`

Automatic demotion (hot DRAM → cold CXL) already exists in `shrink_page_list()`. Extend the demotion path to call `alloc_migration_target_colored()` instead of the default allocator when the target is a CXL node. Promotion (cold CXL → warm DRAM) follows the existing `PG_referenced`/`PG_active` LRU logic, extended with a color-aware allocator callback.

### Summary

| Change | File(s) | Difficulty |
|--------|---------|------------|
| Per-color free lists in `struct zone` | `mmzone.h`, `page_alloc.c` | High — touches hot allocator path |
| `alloc_pages_node_color()` | `page_alloc.c` | Medium |
| `alloc_migration_target_colored()` | `migrate.c` | Low — swap `alloc_fn` pointer |
| `num_cache_colors` at boot | `cacheinfo.c` | Low |
| CXL node mask from HMAT | `hmat.c` | Low–Medium |
| CXL memory online → pre-classify | `memory_hotplug.c` | Medium |
| Auto-demotion hook | `vmscan.c` | Low — existing demotion path |

---

## References

1. H. Li et al., "Pond: CXL-Based Memory Pooling Systems," ACM ASPLOS, 2023.
2. H. A. Maruf et al., "TPP: Transparent Page Placement for CXL-Enabled Tiered Memory," ACM ASPLOS, 2023.
3. Z. Yan et al., "Nimble Page Management for Tiered Memory Systems," ACM ASPLOS, 2019.
4. B. Lepers and W. Zwaenepoel, "Johnny Cache," USENIX OSDI, 2023.
