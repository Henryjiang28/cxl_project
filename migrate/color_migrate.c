/*
 * color_migrate.c
 * Page-color-aware migration alongside baseline_migrate.c
 *
 * Strategy (userspace):
 *   1. Read LLC geometry from sysfs -> compute num_cache_colors
 *      color = pfn % num_colors
 *      where num_colors = cache_sets / (PAGE_SIZE / cache_line_size)
 *   2. Allocate source pages on DRAM; fault them in.
 *   3. Over-allocate a CXL pool (OVERSAMPLE × N_PAGES) on CXL node; fault in.
 *   4. Read /proc/self/pagemap to get PFNs for all pages.
 *      Falls back to virtual-address coloring when PFNs are unreadable (non-root).
 *   5. Build per-color free-lists from the CXL pool.
 *   6. For each source page: pop a same-color CXL slot, memcpy the data.
 *      (In a kernel driver this would be migrate_page() to a specific frame;
 *       in userspace we pre-select the destination frame by color then copy.)
 *   7. Report color-match rate, color histogram, and NUMA placement.
 *
 * Compile: gcc -O2 -Wall -o color_migrate color_migrate.c -lnuma
 * Run:     numactl --cpunodebind=0 ./color_migrate
 * Root:    sudo numactl --cpunodebind=0 ./color_migrate   (for physical PFNs)
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <numa.h>
#include <numaif.h>
#include <sys/mman.h>

/* ---- tunables ---- */
#define DRAM_NODE     0
#define CXL_NODE      2
#define N_PAGES       1024          /* pages to migrate */
#define PAGE_SIZE     4096UL
#define OVERSAMPLE    8             /* CXL pool = OVERSAMPLE × N_PAGES pages */
#define LLC_INDEX     3             /* sysfs index for the L3 (LLC) cache */
#define MAX_COLORS    4096          /* upper bound on color count */

/* ====================================================================
 * 1. LLC geometry -> num_cache_colors
 * ==================================================================== */

static unsigned int g_num_colors  = 32;   /* fallback defaults */
static unsigned int g_cache_sets  = 2048;
static unsigned int g_line_size   = 64;

static int read_sysfs_uint(const char *path, unsigned int *val)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int r = fscanf(f, "%u", val);
    fclose(f);
    return (r == 1) ? 0 : -1;
}

static void detect_llc_geometry(void)
{
    char path[256];
    unsigned int sets = 0, line = 0;

    snprintf(path, sizeof(path),
             "/sys/devices/system/cpu/cpu0/cache/index%d/number_of_sets", LLC_INDEX);
    if (read_sysfs_uint(path, &sets) < 0) goto fallback;

    snprintf(path, sizeof(path),
             "/sys/devices/system/cpu/cpu0/cache/index%d/coherency_line_size", LLC_INDEX);
    if (read_sysfs_uint(path, &line) < 0) goto fallback;

    if (sets == 0 || line == 0) goto fallback;

    {
        unsigned int sets_per_page = (unsigned int)(PAGE_SIZE / line);
        if (sets_per_page == 0) goto fallback;

        g_cache_sets = sets;
        g_line_size  = line;
        g_num_colors = sets / sets_per_page;
        if (g_num_colors == 0) g_num_colors = 1;
        if (g_num_colors > MAX_COLORS) g_num_colors = MAX_COLORS;

        printf("[LLC] detected  sets=%u  line=%uB  sets_per_page=%u  colors=%u\n",
               sets, line, sets_per_page, g_num_colors);
        return;
    }

fallback:
    printf("[LLC] sysfs unavailable; using defaults  sets=%u line=%uB colors=%u\n",
           g_cache_sets, g_line_size, g_num_colors);
}

/* ====================================================================
 * 2. Physical address extraction via /proc/self/pagemap
 *
 * Pagemap entry (8 bytes per page):
 *   bit 63        : page present
 *   bit 62        : page in swap
 *   bits 0-54     : PFN  (zero for non-root since Linux 4.0)
 * ==================================================================== */

static int g_pagemap_fd = -1;
static int g_pfn_readable = 0;  /* set to 1 once we confirm a non-zero PFN */

static void open_pagemap(void)
{
    g_pagemap_fd = open("/proc/self/pagemap", O_RDONLY);
    if (g_pagemap_fd < 0)
        fprintf(stderr, "[pagemap] open failed (%s); coloring via vaddr\n",
                strerror(errno));
}

/* Returns 0 and fills *pfn_out on success; -1 if unreadable / not present. */
static int read_pfn(void *vaddr, uint64_t *pfn_out)
{
    if (g_pagemap_fd < 0) return -1;

    uint64_t vpn   = (uint64_t)(uintptr_t)vaddr / PAGE_SIZE;
    uint64_t entry = 0;

    if (pread(g_pagemap_fd, &entry, sizeof(entry), (off_t)(vpn * 8))
            != (ssize_t)sizeof(entry))
        return -1;

    if (!(entry & (1ULL << 63))) return -1;   /* not present */
    if (  entry & (1ULL << 62))  return -1;   /* swapped */

    uint64_t pfn = entry & 0x007FFFFFFFFFFFFFULL;
    if (pfn == 0) return -1;                  /* no permission (non-root) */

    *pfn_out = pfn;
    return 0;
}

/* ====================================================================
 * 3. Color computation
 *    color = pfn % num_colors               (physical — accurate)
 *    color = vpn % num_colors               (virtual  — fallback)
 * ==================================================================== */

typedef struct {
    uint64_t pfn;
    int      color;
    int      from_phys;   /* 1 = PFN-based, 0 = vaddr-based */
} page_color_t;

static page_color_t get_color(void *vaddr)
{
    page_color_t pc = {0};
    uint64_t pfn;

    if (read_pfn(vaddr, &pfn) == 0) {
        pc.pfn        = pfn;
        pc.color      = (int)(pfn % g_num_colors);
        pc.from_phys  = 1;
        g_pfn_readable = 1;
    } else {
        uint64_t vpn  = (uint64_t)(uintptr_t)vaddr / PAGE_SIZE;
        pc.pfn        = 0;
        pc.color      = (int)(vpn % g_num_colors);
        pc.from_phys  = 0;
    }
    return pc;
}

/* ====================================================================
 * 4. Per-color free lists for CXL pool pages
 *
 * color_slots[c]  = array of void* (CXL virtual addresses with color c)
 * color_count[c]  = how many slots remain (stack: pop from top)
 * ==================================================================== */

static void  ***color_slots = NULL;  /* color_slots[color][index] */
static int    *color_count  = NULL;  /* current stack height      */
static int    *color_cap    = NULL;  /* allocated capacity        */

static int push_slot(int color, void *vaddr)
{
    if (color < 0 || color >= (int)g_num_colors) return -1;
    if (color_count[color] == color_cap[color]) {
        int newcap = color_cap[color] ? color_cap[color] * 2 : 16;
        void **tmp = realloc(color_slots[color], newcap * sizeof(void *));
        if (!tmp) return -1;
        color_slots[color] = tmp;
        color_cap[color]   = newcap;
    }
    color_slots[color][color_count[color]++] = vaddr;
    return 0;
}

static void *pop_slot(int color)
{
    if (color < 0 || color >= (int)g_num_colors) return NULL;
    if (color_count[color] == 0) return NULL;
    return color_slots[color][--color_count[color]];
}

static void *pop_any_slot(void)
{
    for (unsigned int c = 0; c < g_num_colors; c++) {
        void *s = pop_slot((int)c);
        if (s) return s;
    }
    return NULL;
}

static void init_color_lists(void)
{
    color_slots = calloc(g_num_colors, sizeof(void **));
    color_count = calloc(g_num_colors, sizeof(int));
    color_cap   = calloc(g_num_colors, sizeof(int));
    if (!color_slots || !color_count || !color_cap) {
        perror("calloc color lists");
        exit(1);
    }
}

static void free_color_lists(void)
{
    for (unsigned int c = 0; c < g_num_colors; c++)
        free(color_slots[c]);
    free(color_slots);
    free(color_count);
    free(color_cap);
}

/* Classify every page in the CXL pool by color and push onto the free list. */
static void build_color_lists(void *cxl_buf, int n_pool_pages)
{
    int phys_classified = 0, virt_classified = 0;

    for (int i = 0; i < n_pool_pages; i++) {
        void *vaddr = (char *)cxl_buf + (size_t)i * PAGE_SIZE;
        page_color_t pc = get_color(vaddr);
        push_slot(pc.color, vaddr);
        if (pc.from_phys) phys_classified++;
        else              virt_classified++;
    }

    printf("[pool] CXL pool classified: %d physical, %d virtual coloring\n",
           phys_classified, virt_classified);

    /* Distribution summary */
    unsigned int min_c = (unsigned int)n_pool_pages + 1, max_c = 0, nonempty = 0;
    for (unsigned int c = 0; c < g_num_colors; c++) {
        unsigned int cnt = (unsigned int)color_count[c];
        if (cnt > 0) {
            nonempty++;
            if (cnt < min_c) min_c = cnt;
            if (cnt > max_c) max_c = cnt;
        }
    }
    printf("[pool] %u/%u colors populated  min=%u max=%u pages/color\n",
           nonempty, g_num_colors,
           (min_c > (unsigned int)n_pool_pages) ? 0 : min_c, max_c);
}

/* ====================================================================
 * 5. NUMA helpers (mirrors baseline_migrate.c)
 * ==================================================================== */

static void print_page_nodes(void **pages, int n, int *status, const char *label)
{
    if (move_pages(0, (unsigned long)n, pages, NULL, status, 0) != 0) {
        perror("move_pages(query)");
        return;
    }
    int counts[4] = {0}, errs = 0;
    for (int i = 0; i < n; i++) {
        if (status[i] >= 0 && status[i] < 4) counts[status[i]]++;
        else errs++;
    }
    printf("[%-30s] node0=%d node1=%d node2=%d node3=%d err=%d\n",
           label, counts[0], counts[1], counts[2], counts[3], errs);
}

/* ====================================================================
 * 6. Color-preserving migration
 * ==================================================================== */

typedef struct {
    void *src_vaddr;
    void *dst_vaddr;   /* NULL if no slot was available */
    int   src_color;
    int   dst_color;
    int   color_match; /* 1 if src_color == dst_color */
} migration_result_t;

/*
 * color_migrate_pages:
 *   For each source page in src_buf:
 *     - compute source color
 *     - pop a same-color slot from the CXL free lists
 *     - memcpy data to that slot   <-- the "migrate_page" in userspace
 *   Fills results[0..N_PAGES-1].
 */
static void color_migrate_pages(char *src_buf, int n_pages,
                                migration_result_t *results)
{
    int matched = 0, fallback = 0, dropped = 0;

    for (int i = 0; i < n_pages; i++) {
        void *svaddr = src_buf + (size_t)i * PAGE_SIZE;
        page_color_t sc = get_color(svaddr);

        void *dst = pop_slot(sc.color);       /* same-color slot */
        if (!dst) {
            dst = pop_any_slot();             /* color pool exhausted: any slot */
            if (dst) fallback++;
            else     dropped++;
        } else {
            matched++;
        }

        results[i].src_vaddr  = svaddr;
        results[i].src_color  = sc.color;

        if (dst) {
            memcpy(dst, svaddr, PAGE_SIZE);   /* copy data to color-matched CXL frame */
            page_color_t dc       = get_color(dst);
            results[i].dst_vaddr  = dst;
            results[i].dst_color  = dc.color;
            results[i].color_match = (sc.color == dc.color);
        } else {
            results[i].dst_vaddr   = NULL;
            results[i].dst_color   = -1;
            results[i].color_match = 0;
        }
    }

    printf("\n[migration] same-color=%d  fallback=%d  dropped=%d  total=%d\n",
           matched, fallback, dropped, n_pages);
}

/* ====================================================================
 * 7. Statistics helpers
 * ==================================================================== */

static void print_color_histogram(const migration_result_t *r, int n,
                                  unsigned int num_colors)
{
    int *src_hist = calloc(num_colors, sizeof(int));
    int *dst_hist = calloc(num_colors, sizeof(int));
    if (!src_hist || !dst_hist) { free(src_hist); free(dst_hist); return; }

    for (int i = 0; i < n; i++) {
        if (r[i].src_color >= 0 && (unsigned int)r[i].src_color < num_colors)
            src_hist[r[i].src_color]++;
        if (r[i].dst_color >= 0 && (unsigned int)r[i].dst_color < num_colors)
            dst_hist[r[i].dst_color]++;
    }

    printf("\n[color histogram]  color : src_count -> dst_count\n");
    for (unsigned int c = 0; c < num_colors; c++) {
        if (src_hist[c] || dst_hist[c])
            printf("  color %3u : %4d -> %4d%s\n",
                   c, src_hist[c], dst_hist[c],
                   src_hist[c] != dst_hist[c] ? "  *mismatch" : "");
    }

    free(src_hist);
    free(dst_hist);
}

/* ====================================================================
 * main
 * ==================================================================== */

int main(void)
{
    if (numa_available() < 0) {
        fprintf(stderr, "NUMA not available\n");
        return 1;
    }

    detect_llc_geometry();
    open_pagemap();

    printf("\n=== Page-Color-Aware Migration: node %d (DRAM) -> node %d (CXL) ===\n\n",
           DRAM_NODE, CXL_NODE);

    /* --- Allocate source buffer on DRAM --- */
    size_t src_total = (size_t)N_PAGES * PAGE_SIZE;
    char *src_buf = numa_alloc_onnode(src_total, DRAM_NODE);
    if (!src_buf) { perror("numa_alloc_onnode(src)"); return 1; }

    /* Fault in every source page and write a recognizable pattern */
    for (int i = 0; i < N_PAGES; i++)
        src_buf[(size_t)i * PAGE_SIZE] = (char)(i & 0xFF);

    /* --- Allocate CXL pool (OVERSAMPLE × N_PAGES pages) --- */
    int pool_pages  = N_PAGES * OVERSAMPLE;
    size_t pool_total = (size_t)pool_pages * PAGE_SIZE;
    char *cxl_pool = numa_alloc_onnode(pool_total, CXL_NODE);
    if (!cxl_pool) { perror("numa_alloc_onnode(cxl pool)"); return 1; }

    /* Fault in CXL pool pages so their PFNs are assigned */
    for (int i = 0; i < pool_pages; i++)
        cxl_pool[(size_t)i * PAGE_SIZE] = 0;

    /* --- Build per-color free lists from CXL pool --- */
    init_color_lists();
    build_color_lists(cxl_pool, pool_pages);

    if (!g_pfn_readable)
        printf("[warn] PFNs unreadable (need root); colors derived from virtual address\n");

    /* --- NUMA snapshot before migration --- */
    void **src_pages = malloc((size_t)N_PAGES * sizeof(void *));
    int  *status     = malloc((size_t)N_PAGES * sizeof(int));
    for (int i = 0; i < N_PAGES; i++)
        src_pages[i] = src_buf + (size_t)i * PAGE_SIZE;

    print_page_nodes(src_pages, N_PAGES, status, "Source before migration (DRAM)");

    /* --- Color-preserving migration --- */
    migration_result_t *results = calloc((size_t)N_PAGES, sizeof(migration_result_t));
    if (!results) { perror("calloc results"); return 1; }

    color_migrate_pages(src_buf, N_PAGES, results);

    /* --- Aggregate results --- */
    int color_preserved = 0, total_migrated = 0;
    void **dst_pages = malloc((size_t)N_PAGES * sizeof(void *));
    int   dst_n = 0;

    for (int i = 0; i < N_PAGES; i++) {
        if (results[i].dst_vaddr) {
            total_migrated++;
            dst_pages[dst_n++] = results[i].dst_vaddr;
            if (results[i].color_match) color_preserved++;
        }
    }

    printf("[result] pages migrated: %d/%d  color-preserved: %d/%d (%.1f%%)\n",
           total_migrated, N_PAGES,
           color_preserved, total_migrated,
           total_migrated ? 100.0 * color_preserved / total_migrated : 0.0);

    /* --- Verify NUMA placement of destinations --- */
    print_page_nodes(dst_pages, dst_n, status, "Dest after migration  (CXL)  ");

    /* --- Color histogram --- */
    print_color_histogram(results, N_PAGES, g_num_colors);

    /* --- Verify data integrity on a sample of pages --- */
    int corrupt = 0;
    for (int i = 0; i < N_PAGES; i++) {
        if (!results[i].dst_vaddr) continue;
        char expected = (char)(i & 0xFF);
        char got      = ((char *)results[i].dst_vaddr)[0];
        if (got != expected) corrupt++;
    }
    printf("\n[integrity] data corruption: %d/%d pages\n", corrupt, total_migrated);

    /* --- Cleanup --- */
    if (g_pagemap_fd >= 0) close(g_pagemap_fd);
    free_color_lists();
    free(src_pages);
    free(dst_pages);
    free(status);
    free(results);
    numa_free(src_buf, src_total);
    numa_free(cxl_pool, pool_total);
    return 0;
}
