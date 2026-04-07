/*
 * baseline_migrate.c
 * Week 2 里程碑：基线冷页迁移
 * - 在 node 0 分配内存，模拟"冷"页
 * - 用 move_pages() 迁移到 node 2 (CXL)
 * - 验证迁移前后的节点归属
 *
 * 编译: gcc -O2 -o baseline_migrate baseline_migrate.c -lnuma
 * 运行: numactl --cpunodebind=0 ./baseline_migrate
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <numa.h>
#include <numaif.h>
#include <sys/mman.h>
#include <unistd.h>

#define DRAM_NODE  0
#define CXL_NODE   2
#define N_PAGES    1024          /* 迁移 1024 个 4KB 页 = 4 MB */
#define PAGE_SIZE  4096

/* 获取一组虚拟地址的当前 NUMA node */
static void print_page_nodes(void **pages, int *status, int n, const char *label)
{
    int ret = move_pages(0, n, pages, NULL, status, 0);
    if (ret != 0) {
        perror("move_pages(query)");
        return;
    }
    int counts[4] = {0};
    int errs = 0;
    for (int i = 0; i < n; i++) {
        if (status[i] >= 0 && status[i] < 4)
            counts[status[i]]++;
        else
            errs++;
    }
    printf("[%s] pages on node0=%d node1=%d node2=%d node3=%d err=%d\n",
           label, counts[0], counts[1], counts[2], counts[3], errs);
}

int main(void)
{
    if (numa_available() < 0) {
        fprintf(stderr, "NUMA not available\n");
        return 1;
    }

    printf("=== Baseline Page Migration: node %d (DRAM) -> node %d (CXL) ===\n\n",
           DRAM_NODE, CXL_NODE);

    /* 1. 在 DRAM 节点分配内存 */
    size_t total = (size_t)N_PAGES * PAGE_SIZE;
    char *buf = (char *)numa_alloc_onnode(total, DRAM_NODE);
    if (!buf) {
        fprintf(stderr, "numa_alloc_onnode failed: %s\n", strerror(errno));
        return 1;
    }

    /* touch 每一页，确保物理页已分配 */
    for (int i = 0; i < N_PAGES; i++)
        buf[i * PAGE_SIZE] = (char)i;

    /* 2. 构建页地址数组 */
    void **pages  = malloc(N_PAGES * sizeof(void *));
    int  *nodes   = malloc(N_PAGES * sizeof(int));
    int  *status  = malloc(N_PAGES * sizeof(int));

    for (int i = 0; i < N_PAGES; i++) {
        pages[i] = buf + (size_t)i * PAGE_SIZE;
        nodes[i] = CXL_NODE;  /* 目标：迁到 CXL node */
    }

    /* 3. 迁移前：确认在 DRAM */
    print_page_nodes(pages, status, N_PAGES, "Before migration");

    /* 4. move_pages 迁移 */
    int ret = move_pages(0, N_PAGES, pages, nodes, status, MPOL_MF_MOVE);
    if (ret != 0) {
        perror("move_pages(migrate)");
        /* 非致命：部分页可能失败，继续看结果 */
    }

    /* 5. 迁移后：确认在 CXL */
    print_page_nodes(pages, status, N_PAGES, "After  migration");

    /* 统计迁移成功率 */
    int migrated = 0, failed = 0;
    for (int i = 0; i < N_PAGES; i++) {
        if (status[i] == CXL_NODE) migrated++;
        else                       failed++;
    }
    printf("\nMigration success: %d/%d pages (%.1f%%)\n",
           migrated, N_PAGES, 100.0 * migrated / N_PAGES);

    /* 6. 迁回 DRAM（演示双向迁移） */
    for (int i = 0; i < N_PAGES; i++)
        nodes[i] = DRAM_NODE;
    ret = move_pages(0, N_PAGES, pages, nodes, status, MPOL_MF_MOVE);
    print_page_nodes(pages, status, N_PAGES, "After  migration back");

    free(pages); free(nodes); free(status);
    numa_free(buf, total);
    return 0;
}
