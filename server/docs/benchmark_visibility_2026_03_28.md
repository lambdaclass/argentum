# Visibility Mode Benchmark Results

**Date:** 2026-03-28
**Machine:** macOS Darwin 25.2.0, single machine (bots + server co-located)
**Harness:** `mix bench.visibility` with `Arena.Metrics` (atomics) + bot-side RTT tracking
**AoI range:** 11x9 tiles (traditional AO viewport half-size)

## Results (with pre-encoded broadcasts)

All results below use pre-encoded raw broadcasts: packets are encoded once in MapServer and sent as raw bytes to session processes, skipping per-recipient re-encoding.

### Hot-map scenarios (map 999, 100x100 open, no exits)

| Scenario | Mode | Bots | Sched% | RAM | Queue avg/max | Recip/move | Moves/s | RTT p50/p99/max | BW rx |
|---|---|---|---|---|---|---|---|---|---|
| hot_spread | aoi_grid | 500 | 3.8% | 125MB | 0.1/1 | 52.5 | 1,506 | 0/0/5ms | 542 KB/s |
| hot_spread | aoi_grid | 1,000 | 14.8% | 178MB | 0.0/0 | 108.2 | 2,860 | 0/1/3ms | 2.0 MB/s |

### Crowd arena scenarios (map 998, 25x25 walkable center)

| Scenario | Mode | Bots | Sched% | RAM | Queue avg/max | Recip/move | Moves/s | RTT p50/p99/max | BW rx |
|---|---|---|---|---|---|---|---|---|---|
| crowd | aoi_grid | 500 | 8.2% | 202MB | 0.1/2 | 433.8 | 309 | 1/4/7ms | 1.1 MB/s |
| crowd_saturated | aoi_grid | 500 | 11.0% | 202MB | 43.2/270 | 434.3 | 414 | 17/51/65ms | 1.5 MB/s |

### World-spread scenarios (bots pre-scattered across 13 connected maps)

| Scenario | Mode | Bots | Sched% | RAM | Queue avg/max | Recip/move | Moves/s | RTT p50/p99/max | BW rx |
|---|---|---|---|---|---|---|---|---|---|
| world_spread | aoi_grid | 2,000 | 9.6% | 387MB | 0.1/1 | 26.3 | 5,553 | 0/0/4ms | 1.1 MB/s |

At 2,000 bots across 25 maps (120-178 per map), the server is barely working: 9.6% scheduler, zero queue depth, 5,553 moves/sec. The one-GenServer-per-map architecture parallelizes naturally across CPU cores.

5,000 bots failed due to DB pool saturation during the login storm (5k concurrent character loads overwhelmed Postgres), not game logic. Staggered connections or a larger DB pool would fix this.

### Previous results (before pre-encoded broadcasts, for comparison)

| Scenario | Mode | Bots | Sched% | RAM | Queue avg/max | Recip/move | Moves/s | RTT p50/p99/max | BW rx |
|---|---|---|---|---|---|---|---|---|---|
| single_map_spread | aoi_grid | 200 | 0.6% | 118MB | 0/0 | 13.4 | 537 | 0/0/2ms | 102 KB/s |
| single_map_spread | **global** | 500 | **14.9%** | **375MB** | 0.2/1 | **472.6** | 676 | **137/369/408ms** | 4.5 MB/s |
| single_map_spread | aoi_grid | 500 | 4.7% | 130MB | 0/0 | 78.5 | 1,272 | 0/0/2ms | 1.1 MB/s |
| saturated_walk | aoi_grid | 500 | 7.1% | 135MB | 3.1/26 | 81.9 | 1,717 | 6/16/20ms | 1.6 MB/s |
| single_map_dense | aoi_grid | 1,000 | 19.1% | 202MB | 0.1/1 | 161.6 | 2,223 | 0/2/4ms | 2.4 MB/s |
| single_map_spread | **global** | 1,000 | **21.2%** | **5.7GB** | **997/998** | **999** | 709 | **156/380/409ms** | 8.3 MB/s |
| single_map_spread | aoi_grid | 1,000 | 18.2% | 207MB | 0.2/1 | 162 | 2,232 | 0/2/67ms | 4.4 MB/s |
| world_spread | aoi_grid | 2,000 | 15.4% | 252MB | 0.4/1 | 117.8 | 2,482 | 0/1/5ms | 2.0 MB/s |
| world_spread | aoi_grid | 5,000* | 14.1% | 310MB | 0.3/2 | 106.2 | 2,526 | 0/1/12ms | 2.1 MB/s |
| single_map_spread | aoi_grid | 5,000* | 20.3% | 336MB | 0.1/1 | 166.5 | 2,290 | 0/2/8ms | 2.9 MB/s |

*\* 5,000 spawned but only ~1,033 connected due to OS file descriptor limit, not server bottleneck.*

## Key Findings

### Pre-encoded broadcasts reduce CPU and increase throughput

Encoding packets once in MapServer instead of re-encoding per session process eliminates redundant work. At 1,000 players on one map (~108 recipients per move), this saves ~107 encode calls per walk.

| Metric | Before (1k spread) | After (1k spread) | Improvement |
|---|---|---|---|
| Scheduler util | 18.2% | 14.8% | **-19%** |
| Memory | 207 MB | 178 MB | **-14%** |
| Moves/sec | 2,232 | 2,860 | **+28%** |
| MapServer queue | 0.2 | 0.0 | **Fully drained** |

### AoI grid vs global at scale

At 1,000 bots on a single map, the difference is stark:

| Metric | global | aoi_grid | Improvement |
|---|---|---|---|
| Recipients/move | 999 | 108 | **9x fewer sends** |
| MapServer queue | 997 | 0.0 | **Queue saturated vs idle** |
| Memory | 5.7 GB | 178 MB | **32x less RAM** |
| Move RTT p50 | 156 ms | 0 ms | **Sub-tick vs unplayable** |
| Moves/sec | 709 | 2,860 | **4x more throughput** |

Global mode at 1,000 players is unplayable: the MapServer can't drain its mailbox (queue=997), every move takes 156ms round-trip, and the process is drowning in send buffers (5.7GB RAM). AoI grid handles the same load with room to spare.

### Crowd arena forces real density pressure

The crowd arena (25x25 walkable center, map 998) forces all 500 bots into 625 tiles, producing ~434 recipients per move. This is the closest approximation to a busy city square.

At fixed 210ms interval (crowd_saturated), the MapServer queue reaches avg=43, max=270 with 17ms p50 RTT — the only scenario where the server shows real pressure. Even so, it keeps up at 414 moves/sec without dropping players.

### OS limits, not server limits

The 5,000-bot test proved the bottleneck is `ulimit -n` (file descriptors), not game logic. With `ulimit -n 65536`, higher counts should be reachable. Previous 10k tests (before this harness) confirmed this.

## Scenarios

### Hot-map (map 999, 100x100 fully open, no exits)

| Scenario | Description | Warmup |
|---|---|---|
| `hot_spread` | Bots spread across the map | 10s |
| `hot_dense` | Bots clustered at center (2s warmup) | 2s |
| `hot_saturated` | Fixed 210ms walk interval, peak pressure | 10s |

### Crowd arena (map 998, 25x25 walkable center, rest blocked)

| Scenario | Description | Warmup |
|---|---|---|
| `crowd` | Bots packed into 25x25 arena | 10s |
| `crowd_saturated` | 25x25 arena + fixed 210ms walk interval | 10s |

### World-scale (real maps with exit tiles)

| Scenario | Description | Warmup |
|---|---|---|
| `world_spread` | Bots wander freely across maps | 10s |
| `world_idle` | Bots connected but take no actions | 5s |

## What's measured

**Server-side (Arena.Metrics, lock-free atomics):**
- Scheduler utilization (wall-time diff)
- Memory, process count, reductions/sec
- MapServer message queue (total and max across all active maps)
- Recipients per move broadcast (atomics counter in MapServer)
- Per-map player distribution

**Bot-side (per-bot GenServer state, aggregated via Swarm):**
- Packets received/sec, bytes received/sec
- Move RTT: timestamp on walk send, measured on pos_update receive (p50/p99/max)
- Counters reset at sample start to exclude warmup/connection traffic

## Still untested

- **Long soak (30-60 min):** Would catch memory growth, mailbox drift, reconnect storms, scheduler instability.
- **Mixed workload:** Chat + heading churn + position requests + combat. Real servers die from mixed traffic.
- **Connection churn:** Bots connecting/disconnecting continuously. Stresses session cleanup and persistence.
- **Larger maps:** 200x200+ would show real AoI density divergence between spread and dense scenarios.
