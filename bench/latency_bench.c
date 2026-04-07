/*
 * latency_bench.c
 * 验证 NUMA node 0 (DRAM) vs node 2 (CXL-emulated) 的访问延迟差异
 * 编译: gcc -O2 -o latency_bench latency_bench.c -lnuma
 * 运行: numactl --cpunodebind=0 ./latency_bench
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sched.h>
#include <numa.h>
#include <numaif.h>

#define BUF_SIZE   (256 * 1024 * 1024)  /* 256 MB, 超过 LLC 大小 */
#define STRIDE     (4096)                /* 4KB, 跨 page 访问 */
#define ITERATIONS (10000000)

static uint64_t rdtsc(void)
{
    uint32_t lo, hi;
    __asm__ __volatile__("rdtsc" : "=a"(lo), "=d"(hi));
    return ((uint64_t)hi << 32) | lo;
}

static double measure_latency(void *buf, size_t size, int iters)
{
    volatile char *p = (volatile char *)buf;
    size_t n_pages = size / STRIDE;
    uint64_t start, end;
    long sum = 0;

    /* 先 warm-up (但超过 LLC，会 miss) */
    for (size_t i = 0; i < n_pages; i++)
        p[i * STRIDE] = (char)i;

    start = rdtsc();
    for (int i = 0; i < iters; i++) {
        sum += p[(i % n_pages) * STRIDE];
    }
    end = rdtsc();

    (void)sum;
    return (double)(end - start) / iters;  /* cycles per access */
}

int main(void)
{
    if (numa_available() < 0) {
        fprintf(stderr, "NUMA not available\n");
        return 1;
    }

    int n_nodes = numa_num_configured_nodes();
    printf("NUMA nodes: %d\n", n_nodes);
    printf("Running on node: %d\n", numa_node_of_cpu(sched_getcpu()));
    printf("BUF_SIZE = %d MB (should exceed LLC)\n\n", (int)(BUF_SIZE >> 20));

    int test_nodes[] = {0, 1, 2, 3};
    int n_test = 4;

    for (int ni = 0; ni < n_test; ni++) {
        int node = test_nodes[ni];
        if (node >= n_nodes) continue;

        void *buf = numa_alloc_onnode(BUF_SIZE, node);
        if (!buf) {
            printf("node %d: alloc failed\n", node);
            continue;
        }

        double cycles = measure_latency(buf, BUF_SIZE, ITERATIONS);
        printf("node %d (%s): %.1f cycles/access\n",
               node,
               node == 0 ? "DRAM" : node == 2 ? "CXL-emu" : "NUMA",
               cycles);

        numa_free(buf, BUF_SIZE);
    }

    printf("\n=> node 2 / node 0 ratio is your CXL emulation overhead\n");
    return 0;
}
