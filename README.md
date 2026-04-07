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
    └── baseline_migrate.c    # Baseline cold-page migration using move_pages()
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

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make all` | Build all binaries |
| `make clean` | Remove binaries |
| `make check` | Print NUMA topology and node distances |
| `make run-latency` | Run latency benchmark (CPU bound to node 0) |
| `make run-migrate` | Run baseline migration test |

---

## Project Milestones

| Week | Goal | Status |
|------|------|--------|
| 2 | NUMA CXL emulation setup; baseline `move_pages()` migration; verify latency difference | **Done** |
| 4 | Hotness tracker (accessed-bit scan / perf sampling); cache color extractor; baseline experiments | Planned |
| 6 | Color-preserving migration; full evaluation vs. all baselines; final poster | Planned |

---

## Next Steps (Week 4)

- **Hotness Tracker:** Scan `/proc/PID/pagemap` + accessed bits (or use `perf` sampling) to classify pages as hot/cold.
- **Cache Color Extractor:** Read physical addresses from `/proc/PID/pagemap` and compute:
  ```
  color = (phys_addr / PAGE_SIZE) % num_cache_colors
  ```
  For a 16 MB LLC with 2048 sets: `num_cache_colors = cache_sets / sets_per_page`.
- **Color-Preserving Migrator:** Maintain per-color free lists on node 2; when migrating a cold page, select a destination frame whose cache color matches the source.

---

## References

1. H. Li et al., "Pond: CXL-Based Memory Pooling Systems," ACM ASPLOS, 2023.
2. H. A. Maruf et al., "TPP: Transparent Page Placement for CXL-Enabled Tiered Memory," ACM ASPLOS, 2023.
3. Z. Yan et al., "Nimble Page Management for Tiered Memory Systems," ACM ASPLOS, 2019.
4. B. Lepers and W. Zwaenepoel, "Johnny Cache," USENIX OSDI, 2023.
