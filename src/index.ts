import { loadTest10_CombinedStress } from "./loadTests";

async function main(): Promise<void> {
  const result = await loadTest10_CombinedStress(30);
  process.exitCode = result.summary.failedIterations > 0 ? 1 : 0;
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
