CC      = gcc
CFLAGS  = -O2 -Wall -g
LDFLAGS = -lnuma

TARGETS = bench/latency_bench migrate/baseline_migrate

all: $(TARGETS)

bench/latency_bench: bench/latency_bench.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

migrate/baseline_migrate: migrate/baseline_migrate.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f $(TARGETS)


check:
	@echo "=== NUMA topology ==="
	numactl --hardware
	@echo ""
	@echo "=== Node distances (node2 is CXL-emulated) ==="
	numactl --hardware | grep -A6 "distances"
	@echo ""
	@echo "=== Current NUMA stats ==="
	numastat | head -6


run-latency: bench/latency_bench
	numactl --cpunodebind=0 --membind=0 ./bench/latency_bench


run-migrate: migrate/baseline_migrate
	numactl --cpunodebind=0 ./migrate/baseline_migrate

.PHONY: all clean check run-latency run-migrate
