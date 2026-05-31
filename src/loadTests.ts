export interface StressTestConfig {
  /** HTTP endpoint to hammer on each iteration. Defaults to httpbin.org/get. */
  httpUrl?: string;
  /** Number of concurrent HTTP requests per iteration. Defaults to 5. */
  httpConcurrency?: number;
  /** Fibonacci depth for CPU stress. Higher = more CPU burn. Defaults to 42. */
  fibDepth?: number;
  /** MB of Float64 data to allocate per iteration for memory stress. Defaults to 30. */
  memoryStressMB?: number;
  /** Milliseconds to wait between iterations. Defaults to 0. */
  iterationDelayMs?: number;
}

export interface IterationResult {
  iteration: number;
  cpuDurationMs: number;
  memoryAllocatedMB: number;
  heapUsedMB: number;
  httpResults: HttpCallResult[];
  totalDurationMs: number;
  errors: string[];
}

export interface HttpCallResult {
  status: number;
  durationMs: number;
  error?: string;
}

export interface LoadTestSummary {
  totalIterations: number;
  successfulIterations: number;
  failedIterations: number;
  avgTotalDurationMs: number;
  minTotalDurationMs: number;
  maxTotalDurationMs: number;
  avgCpuDurationMs: number;
  avgMemoryAllocatedMB: number;
  avgHeapUsedMB: number;
  httpStats: {
    totalRequests: number;
    successfulRequests: number;
    failedRequests: number;
    avgDurationMs: number;
    minDurationMs: number;
    maxDurationMs: number;
  };
}

export interface LoadTestResult {
  config: Required<StressTestConfig>;
  iterations: IterationResult[];
  summary: LoadTestSummary;
  durationMs: number;
}

// Iterative Fibonacci — intentionally CPU-bound
function computeFib(n: number): bigint {
  let a = 0n, b = 1n;
  for (let i = 0; i < n; i++) {
    [a, b] = [b, a + b];
  }
  return a;
}

// Allocate a Float64Array and fill it to stress the memory allocator + GC
function allocateMemory(sizeMB: number): number {
  const count = Math.floor((sizeMB * 1024 * 1024) / 8);
  const buf = new Float64Array(count);
  let checksum = 0;
  for (let i = 0; i < count; i++) {
    buf[i] = Math.sin(i) * Math.cos(i);
    checksum += buf[i];
  }
  return checksum; // Return value prevents dead-code elimination
}

async function httpGet(url: string): Promise<HttpCallResult> {
  const start = Date.now();
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    return { status: res.status, durationMs: Date.now() - start };
  } catch (err) {
    return {
      status: 0,
      durationMs: Date.now() - start,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function runIteration(
  index: number,
  config: Required<StressTestConfig>
): Promise<IterationResult> {
  const start = Date.now();
  const errors: string[] = [];

  // CPU stress — use performance.now() for sub-millisecond precision
  const cpuStart = performance.now();
  try {
    computeFib(config.fibDepth);
  } catch (e) {
    errors.push(`CPU: ${e instanceof Error ? e.message : String(e)}`);
  }
  const cpuDurationMs = performance.now() - cpuStart;

  // Memory stress
  let memoryAllocatedMB = 0;
  try {
    allocateMemory(config.memoryStressMB);
    memoryAllocatedMB = config.memoryStressMB;
  } catch (e) {
    errors.push(`Memory: ${e instanceof Error ? e.message : String(e)}`);
  }

  // HTTP stress — fire httpConcurrency requests concurrently
  const httpPromises = Array.from({ length: config.httpConcurrency }, () =>
    httpGet(config.httpUrl)
  );
  const httpResults = await Promise.all(httpPromises);
  httpResults.forEach((r) => {
    if (r.error) errors.push(`HTTP error: ${r.error}`);
    else if (r.status < 200 || r.status >= 400) errors.push(`HTTP ${r.status}`);
  });

  return {
    iteration: index,
    cpuDurationMs,
    memoryAllocatedMB,
    heapUsedMB: process.memoryUsage().heapUsed / 1024 / 1024,
    httpResults,
    totalDurationMs: Date.now() - start,
    errors,
  };
}

function buildSummary(
  results: IterationResult[],
  config: Required<StressTestConfig>
): LoadTestSummary {
  const n = results.length;
  const totalDurations = results.map((r) => r.totalDurationMs);
  const cpuDurations = results.map((r) => r.cpuDurationMs);
  const heapValues = results.map((r) => r.heapUsedMB);
  const memValues = results.map((r) => r.memoryAllocatedMB);

  const allHttp = results.flatMap((r) => r.httpResults);
  const httpSuccesses = allHttp.filter((h) => h.status >= 200 && h.status < 400);
  const httpDurations = allHttp.map((h) => h.durationMs);

  const avg = (arr: number[]) =>
    arr.length ? arr.reduce((s, v) => s + v, 0) / arr.length : 0;
  const min = (arr: number[]) => (arr.length ? Math.min(...arr) : 0);
  const max = (arr: number[]) => (arr.length ? Math.max(...arr) : 0);

  return {
    totalIterations: n,
    successfulIterations: results.filter((r) => r.errors.length === 0).length,
    failedIterations: results.filter((r) => r.errors.length > 0).length,
    avgTotalDurationMs: avg(totalDurations),
    minTotalDurationMs: min(totalDurations),
    maxTotalDurationMs: max(totalDurations),
    avgCpuDurationMs: avg(cpuDurations),
    avgMemoryAllocatedMB: avg(memValues),
    avgHeapUsedMB: avg(heapValues),
    httpStats: {
      totalRequests: allHttp.length,
      successfulRequests: httpSuccesses.length,
      failedRequests: allHttp.length - httpSuccesses.length,
      avgDurationMs: avg(httpDurations),
      minDurationMs: min(httpDurations),
      maxDurationMs: max(httpDurations),
    },
  };
}

/**
 * Load test #10 — Combined Stress
 *
 * Each iteration applies three simultaneous stressors:
 *   1. CPU  — iterative Fibonacci to depth `fibDepth`
 *   2. Memory — allocates and writes `memoryStressMB` MB of Float64 data
 *   3. HTTP  — fires `httpConcurrency` concurrent GET requests to `httpUrl`
 *
 * @param iterations  Number of sequential stress iterations to execute
 * @param config      Optional tuning overrides
 */
export async function loadTest10_CombinedStress(
  iterations: number,
  config: StressTestConfig = {}
): Promise<LoadTestResult> {
  const resolved: Required<StressTestConfig> = {
    httpUrl: config.httpUrl ?? "https://httpbin.org/get",
    httpConcurrency: config.httpConcurrency ?? 5,
    fibDepth: config.fibDepth ?? 42,
    memoryStressMB: config.memoryStressMB ?? 30,
    iterationDelayMs: config.iterationDelayMs ?? 0,
  };

  console.log("\n=== loadTest10_CombinedStress ===");
  console.log(`  Iterations      : ${iterations}`);
  console.log(`  HTTP URL        : ${resolved.httpUrl}`);
  console.log(`  HTTP concurrency: ${resolved.httpConcurrency} req/iter`);
  console.log(`  CPU fib depth   : ${resolved.fibDepth}`);
  console.log(`  Memory stress   : ${resolved.memoryStressMB} MB/iter`);
  console.log("=================================\n");

  const suiteStart = Date.now();
  const results: IterationResult[] = [];

  for (let i = 1; i <= iterations; i++) {
    const result = await runIteration(i, resolved);
    results.push(result);

    const httpOk = result.httpResults.filter((h) => h.status >= 200 && h.status < 400).length;
    const httpTotal = result.httpResults.length;
    const status = result.errors.length === 0 ? "OK" : `WARN(${result.errors.length} err)`;

    console.log(
      `  [${String(i).padStart(3)}/${iterations}]` +
        `  total=${result.totalDurationMs}ms` +
        `  cpu=${result.cpuDurationMs.toFixed(2)}ms` +
        `  heap=${result.heapUsedMB.toFixed(1)}MB` +
        `  http=${httpOk}/${httpTotal} ok` +
        `  [${status}]`
    );

    if (resolved.iterationDelayMs > 0) {
      await new Promise((r) => setTimeout(r, resolved.iterationDelayMs));
    }
  }

  const durationMs = Date.now() - suiteStart;
  const summary = buildSummary(results, resolved);

  console.log("\n=== Summary ===");
  console.log(`  Total time      : ${durationMs}ms`);
  console.log(`  Iterations      : ${summary.successfulIterations}/${iterations} succeeded`);
  console.log(`  Avg iteration   : ${summary.avgTotalDurationMs.toFixed(0)}ms`);
  console.log(`  Avg CPU         : ${summary.avgCpuDurationMs.toFixed(2)}ms`);
  console.log(`  Avg heap        : ${summary.avgHeapUsedMB.toFixed(1)}MB`);
  console.log(`  HTTP requests   : ${summary.httpStats.successfulRequests}/${summary.httpStats.totalRequests} succeeded`);
  console.log(`  HTTP avg latency: ${summary.httpStats.avgDurationMs.toFixed(0)}ms`);
  console.log("===============\n");

  return { config: resolved, iterations: results, summary, durationMs };
}
