import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const env = {
  ...(typeof process !== "undefined" ? process.env : {}),
  ...(globalThis.foodFinderBenchmarkConfig || {})
};
const endpoint = env.FOODFINDER_ENDPOINT || "http://localhost:8787/api/analyze";
const provider = env.FOODFINDER_PROVIDER || "gemini";
const model = env.FOODFINDER_MODEL || "gemini-flash-latest";
const apiKey = env.FOODFINDER_AI_API_KEY || "";
const usdaKey = env.FOODFINDER_USDA_API_KEY || "";
const language = env.FOODFINDER_LANGUAGE || "nl";
const maxCases = Number(env.FOODFINDER_MAX_CASES || 5);
const caseSetSize = Number(env.FOODFINDER_CASE_SET_SIZE || maxCases);
const caseStart = Number(env.FOODFINDER_CASE_START || 0);
const sampleOffset = Number(env.FOODFINDER_SAMPLE_OFFSET || 0.25);
const composeWithAI = env.FOODFINDER_COMPOSE_WITH_AI === "true";
const carbSafetyMode = env.FOODFINDER_CARB_SAFETY_MODE || "doseGuard";
const useOpenFoodFacts = env.FOODFINDER_USE_OPENFOODFACTS !== "false";
const concurrency = Math.max(1, Number(env.FOODFINDER_CONCURRENCY || 1));
const runLabel = env.FOODFINDER_RUN_LABEL || "";
const historyPath = env.FOODFINDER_HISTORY_PATH || join(root, "benchmark_history.json");
const reportPath = env.FOODFINDER_REPORT_PATH || join(root, "benchmark_report.html");
const printBrief = env.FOODFINDER_PRINT_BRIEF === "true";

const metadataFiles = [
  "dish_metadata_cafe1.csv",
  "dish_metadata_cafe2.csv"
];

await ensureNutrition5kMetadata();

const cases = (await selectCases(caseSetSize)).slice(caseStart, caseStart + maxCases);
const results = await runCases(cases);

const report = score(results);
if (runLabel) {
  await writeRunArtifacts(report);
}
console.log(JSON.stringify(printBrief ? briefReport(report) : report, null, 2));

async function runCases(selectedCases) {
  const results = new Array(selectedCases.length);
  let nextIndex = 0;
  const workerCount = Math.min(concurrency, selectedCases.length);
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < selectedCases.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await runCase(selectedCases[index]);
    }
  }));
  return results;
}

async function runCase(test) {
  const started = Date.now();
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      provider,
      model,
      apiKey,
      usdaKey,
      language,
      mealText: test.text,
      useAI: Boolean(apiKey),
      useOpenFoodFacts,
      composeWithAI,
      carbSafetyMode,
      images: []
    })
  });
  const json = await response.json();
  return {
    id: test.id,
    text: test.text,
    ok: response.ok,
    ms: Date.now() - started,
    truth: test.truth,
    pred: totals(json.final),
    items: (json.final?.items || []).map(item => ({
      name: item.name,
      portion: item.portion,
      carbs: item.carbs,
      fat: item.fat,
      protein: item.protein,
      calories: item.calories,
      source: item.source
    })),
    failed: (json.toolLog || []).filter(entry => entry.status === "failed").map(entry => ({
      type: entry.type,
      name: entry.name,
      error: entry.error
    })),
    aiPrompts: (json.toolLog || []).filter(entry => entry.type === "ai" && entry.status === "started").length
  };
}

async function ensureNutrition5kMetadata() {
  await mkdir(root, { recursive: true });
  for (const file of metadataFiles) {
    const target = join(root, file);
    if (existsSync(target)) continue;
    const url = `https://storage.googleapis.com/nutrition5k_dataset/nutrition5k_dataset/metadata/${file}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Could not download ${file}: HTTP ${response.status}`);
    await writeFile(target, await response.text(), "utf8");
  }
}

async function selectCases(targetCount = maxCases) {
  const rows = [];
  for (const file of metadataFiles) {
    const text = await readFile(join(root, file), "utf8");
    for (const line of text.trim().split(/\r?\n/)) {
      const cols = splitCSVLine(line);
      const id = cols[0];
      const ingredientCount = Math.floor((cols.length - 6) / 7);
      if (!id || ingredientCount < 2 || ingredientCount > 5) continue;

      const ingredients = [];
      for (let index = 0; index < ingredientCount; index += 1) {
        const base = 6 + index * 7;
        ingredients.push({
          name: cleanName(cols[base + 1]),
          grams: Number(cols[base + 2]) || 0
        });
      }
      if (ingredients.some(item => !item.name || item.grams <= 0)) continue;

      const names = ingredients.map(item => item.name.toLowerCase()).join(" ");
      if (!/(rice|pasta|spaghetti|noodle|bread|potato|banana|apple|pizza|chicken|salmon|egg|oat|yogurt|beans|tortilla|cheese|beef|pork|shrimp|vegetable|broccoli|carrot|corn|tomato|sauce)/.test(names)) {
        continue;
      }

      const truth = {
        calories: Number(cols[1]) || 0,
        fat: Number(cols[3]) || 0,
        carbs: Number(cols[4]) || 0,
        protein: Number(cols[5]) || 0
      };
      if (truth.calories <= 0 || (truth.fat + truth.carbs + truth.protein) <= 0) continue;

      rows.push({
        id,
        text: ingredients.map(item => `${Math.round(item.grams)}g ${item.name}`).join(", "),
        truth
      });
    }
  }

  const selected = [];
  const seen = new Set();
  const step = Math.max(1, Math.floor(rows.length / Math.max(targetCount, 1)));
  for (let index = Math.floor(step * sampleOffset); selected.length < targetCount && index < rows.length; index += step) {
    const signature = rows[index].text.replace(/\d+g /g, "");
    if (seen.has(signature)) continue;
    selected.push(rows[index]);
    seen.add(signature);
  }
  return selected;
}

function totals(final) {
  return (final?.items || []).reduce((sum, item) => {
    sum.calories += Number(item.calories) || 0;
    sum.fat += Number(item.fat) || 0;
    sum.carbs += Number(item.carbs) || 0;
    sum.protein += Number(item.protein) || 0;
    return sum;
  }, { calories: 0, fat: 0, carbs: 0, protein: 0 });
}

function score(results) {
  const keys = ["carbs", "protein", "fat", "calories"];
  const carbErrors = results.map(row => Math.abs(row.pred.carbs - row.truth.carbs)).sort((a, b) => a - b);
  const signedCarbErrors = results.map(row => row.pred.carbs - row.truth.carbs);
  const positiveCarbErrors = signedCarbErrors.filter(error => error > 0).sort((a, b) => a - b);
  const negativeCarbErrors = signedCarbErrors.filter(error => error < 0).map(error => Math.abs(error)).sort((a, b) => a - b);
  const positiveMAE = mean(positiveCarbErrors);
  const negativeMAE = mean(negativeCarbErrors);
  const maxPositive = positiveCarbErrors.length ? positiveCarbErrors[positiveCarbErrors.length - 1] : 0;
  const maxNegative = negativeCarbErrors.length ? negativeCarbErrors[negativeCarbErrors.length - 1] : 0;
  const worstCases = [...results]
    .sort((a, b) => Math.abs(b.pred.carbs - b.truth.carbs) - Math.abs(a.pred.carbs - a.truth.carbs))
    .slice(0, 8);
  const worstPositiveCases = [...results]
    .filter(row => row.pred.carbs - row.truth.carbs > 0)
    .sort((a, b) => (b.pred.carbs - b.truth.carbs) - (a.pred.carbs - a.truth.carbs))
    .slice(0, 8);
  const groundedItemRate = round1(results.reduce((sum, row) => {
    const grounded = row.items.filter(item => item.source && item.source !== "aiEstimate").length;
    return sum + (row.items.length ? grounded / row.items.length : 0);
  }, 0) / Math.max(results.length, 1) * 100);
  const safetyPass = maxPositive <= 5 && negativeMAE < 5 && groundedItemRate > 90;
  return {
    config: {
      endpoint,
      provider,
      model,
      maxCases,
      caseSetSize,
      caseStart,
      sampleOffset,
      composeWithAI,
      carbSafetyMode,
      useOpenFoodFacts,
      concurrency,
      hasAIKey: Boolean(apiKey),
      hasUSDAKey: Boolean(usdaKey)
    },
    n: results.length,
    aiPrompts: results.reduce((sum, row) => sum + row.aiPrompts, 0),
    meanAbsoluteError: Object.fromEntries(keys.map(key => [
      key,
      round1(results.reduce((sum, row) => sum + Math.abs(row.pred[key] - row.truth[key]), 0) / Math.max(results.length, 1))
    ])),
    medianCarbAbsoluteError: round1(percentile(carbErrors, 0.5)),
    p90CarbAbsoluteError: round1(percentile(carbErrors, 0.9)),
    signedCarbError: {
      mean: round1(mean(signedCarbErrors)),
      positiveCount: positiveCarbErrors.length,
      negativeCount: negativeCarbErrors.length,
      positiveMeanAbsoluteError: round1(positiveMAE),
      negativeMeanAbsoluteError: round1(negativeMAE),
      maxPositive: round1(maxPositive),
      maxNegative: round1(maxNegative),
      positiveP90: round1(percentile(positiveCarbErrors, 0.9)),
      negativeP90: round1(percentile(negativeCarbErrors, 0.9))
    },
    doseGuardScore: round1(positiveMAE * 4 + maxPositive * 2 + negativeMAE),
    safetyPass,
    meanCarbPercentError: round1(results.reduce((sum, row) =>
      sum + Math.abs(row.pred.carbs - row.truth.carbs) / Math.max(1, row.truth.carbs) * 100, 0
    ) / Math.max(results.length, 1)),
    groundedItemRate,
    worstCases: worstCases.map(row => ({
      id: row.id,
      text: row.text,
      signedCarbError: round1(row.pred.carbs - row.truth.carbs),
      carbAbsError: round1(Math.abs(row.pred.carbs - row.truth.carbs)),
      predCarbs: round1(row.pred.carbs),
      trueCarbs: round1(row.truth.carbs),
      predCalories: round1(row.pred.calories),
      trueCalories: round1(row.truth.calories),
      grounded: `${row.items.filter(item => item.source && item.source !== "aiEstimate").length}/${row.items.length}`
    })),
    worstPositiveCases: worstPositiveCases.map(row => ({
      id: row.id,
      text: row.text,
      signedCarbError: round1(row.pred.carbs - row.truth.carbs),
      predCarbs: round1(row.pred.carbs),
      trueCarbs: round1(row.truth.carbs),
      predCalories: round1(row.pred.calories),
      trueCalories: round1(row.truth.calories),
      grounded: `${row.items.filter(item => item.source && item.source !== "aiEstimate").length}/${row.items.length}`
    })),
    cases: results.map(row => ({
      id: row.id,
      text: row.text,
      signedCarbError: round1(row.pred.carbs - row.truth.carbs),
      predCarbs: round1(row.pred.carbs),
      trueCarbs: round1(row.truth.carbs),
      predCalories: round1(row.pred.calories),
      trueCalories: round1(row.truth.calories),
      grounded: `${row.items.filter(item => item.source && item.source !== "aiEstimate").length}/${row.items.length}`,
      failed: row.failed
    }))
  };
}

function briefReport(report) {
  return {
    label: runLabel,
    n: report.n,
    aiPrompts: report.aiPrompts,
    meanAbsoluteError: report.meanAbsoluteError,
    medianCarbAbsoluteError: report.medianCarbAbsoluteError,
    p90CarbAbsoluteError: report.p90CarbAbsoluteError,
    signedCarbError: report.signedCarbError,
    doseGuardScore: report.doseGuardScore,
    safetyPass: report.safetyPass,
    meanCarbPercentError: report.meanCarbPercentError,
    groundedItemRate: report.groundedItemRate,
    worstPositiveCases: report.worstPositiveCases.slice(0, 3),
    worstCases: report.worstCases.slice(0, 3)
  };
}

async function writeRunArtifacts(report) {
  const history = await readHistory();
  const entry = {
    label: runLabel,
    timestamp: new Date().toISOString(),
    n: report.n,
    aiPrompts: report.aiPrompts,
    config: {
      provider: report.config.provider,
      model: report.config.model,
      caseSetSize: report.config.caseSetSize,
      caseStart: report.config.caseStart,
      sampleOffset: report.config.sampleOffset,
      composeWithAI: report.config.composeWithAI,
      carbSafetyMode: report.config.carbSafetyMode,
      concurrency: report.config.concurrency,
      hasAIKey: report.config.hasAIKey,
      hasUSDAKey: report.config.hasUSDAKey
    },
    meanAbsoluteError: report.meanAbsoluteError,
    medianCarbAbsoluteError: report.medianCarbAbsoluteError,
    p90CarbAbsoluteError: report.p90CarbAbsoluteError,
    signedCarbError: report.signedCarbError,
    doseGuardScore: report.doseGuardScore,
    safetyPass: report.safetyPass,
    meanCarbPercentError: report.meanCarbPercentError,
    groundedItemRate: report.groundedItemRate,
    worstCases: report.worstCases,
    worstPositiveCases: report.worstPositiveCases,
    cases: report.cases
  };
  const existingIndex = history.findIndex(item => item.label === runLabel);
  if (existingIndex >= 0) {
    history[existingIndex] = entry;
  } else {
    history.push(entry);
  }
  await writeFile(historyPath, JSON.stringify(history, null, 2), "utf8");
  await writeFile(reportPath, renderHistoryHTML(history), "utf8");
}

async function readHistory() {
  if (!existsSync(historyPath)) return [];
  try {
    const parsed = JSON.parse(await readFile(historyPath, "utf8"));
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function renderHistoryHTML(history) {
  const entries = history.filter(item => item.meanAbsoluteError?.carbs !== undefined);
  const maxCarb = Math.max(1, ...entries.map(item => item.meanAbsoluteError.carbs));
  const maxGroundingGap = Math.max(1, ...entries.map(item => 100 - (item.groundedItemRate || 0)));
  const maxDoseGuard = Math.max(1, ...entries.map(item => item.doseGuardScore || item.meanAbsoluteError.carbs));
  const points = entries.map((item, index) => {
    const x = entries.length === 1 ? 40 : 40 + index * (620 / (entries.length - 1));
    const y = 240 - (item.meanAbsoluteError.carbs / maxCarb) * 190;
    const groundedY = 240 - ((100 - (item.groundedItemRate || 0)) / maxGroundingGap) * 190;
    const doseGuardY = 240 - (((item.doseGuardScore || item.meanAbsoluteError.carbs) / maxDoseGuard) * 190);
    return { item, x, y, groundedY, doseGuardY };
  });
  const carbPolyline = points.map(point => `${round1(point.x)},${round1(point.y)}`).join(" ");
  const groundedPolyline = points.map(point => `${round1(point.x)},${round1(point.groundedY)}`).join(" ");
  const doseGuardPolyline = points.map(point => `${round1(point.x)},${round1(point.doseGuardY)}`).join(" ");
  const rows = entries.map(item => `
      <tr>
        <td>${escapeHTML(item.label)}</td>
        <td>${item.n}</td>
        <td>${item.aiPrompts}</td>
        <td>${item.meanAbsoluteError.carbs} g</td>
        <td>${item.signedCarbError?.maxPositive ?? "?"} g</td>
        <td>${item.signedCarbError?.positiveMeanAbsoluteError ?? "?"} g</td>
        <td>${item.signedCarbError?.negativeMeanAbsoluteError ?? "?"} g</td>
        <td>${item.doseGuardScore ?? "?"}</td>
        <td>${item.safetyPass ? "yes" : "no"}</td>
        <td>${item.medianCarbAbsoluteError} g</td>
        <td>${item.p90CarbAbsoluteError} g</td>
        <td>${item.meanAbsoluteError.calories} kcal</td>
        <td>${item.groundedItemRate}%</td>
      </tr>`).join("");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FoodFinder Benchmark History</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; padding: 28px; background: #f6f6f8; color: #111; }
    main { max-width: 980px; margin: 0 auto; }
    h1 { margin: 0 0 6px; font-size: 30px; }
    .muted { color: #6b7280; }
    .panel { background: white; border: 1px solid #e5e7eb; border-radius: 14px; padding: 18px; margin-top: 18px; box-shadow: 0 8px 24px rgba(0,0,0,.04); }
    svg { width: 100%; height: auto; display: block; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; }
    th, td { padding: 10px 8px; border-bottom: 1px solid #ececf1; text-align: right; }
    th:first-child, td:first-child { text-align: left; }
    .legend { display: flex; gap: 18px; align-items: center; margin-top: 10px; font-size: 14px; }
    .swatch { display: inline-block; width: 14px; height: 4px; border-radius: 4px; margin-right: 6px; vertical-align: middle; }
    @media (prefers-color-scheme: dark) {
      body { background: #111318; color: #f4f4f5; }
      .panel { background: #181b22; border-color: #2a2f3a; }
      th, td { border-color: #2a2f3a; }
      .muted { color: #a1a1aa; }
    }
  </style>
</head>
<body>
  <main>
    <h1>FoodFinder Benchmark History</h1>
    <div class="muted">Lower carb MAE is better. Grounding gap is 100% minus grounded item rate, so lower is also better.</div>
    <section class="panel">
      <svg viewBox="0 0 700 270" role="img" aria-label="Benchmark score evolution">
        <line x1="40" y1="50" x2="40" y2="240" stroke="#d4d4d8"/>
        <line x1="40" y1="240" x2="670" y2="240" stroke="#d4d4d8"/>
        <polyline points="${carbPolyline}" fill="none" stroke="#0a84ff" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
        <polyline points="${doseGuardPolyline}" fill="none" stroke="#ff3b30" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
        <polyline points="${groundedPolyline}" fill="none" stroke="#34c759" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>
        ${points.map(point => `<circle cx="${round1(point.x)}" cy="${round1(point.y)}" r="5" fill="#0a84ff"><title>${escapeHTML(point.item.label)}: ${point.item.meanAbsoluteError.carbs}g carb MAE</title></circle>`).join("")}
        ${points.map(point => `<text x="${round1(point.x)}" y="258" font-size="10" text-anchor="middle" fill="currentColor">${escapeHTML(shortLabel(point.item.label))}</text>`).join("")}
      </svg>
      <div class="legend">
        <span><span class="swatch" style="background:#0a84ff"></span>Carb MAE</span>
        <span><span class="swatch" style="background:#ff3b30"></span>Dose-guard score</span>
        <span><span class="swatch" style="background:#34c759"></span>Grounding gap</span>
      </div>
    </section>
    <section class="panel">
      <table>
        <thead><tr><th>Version</th><th>n</th><th>AI prompts</th><th>Carb MAE</th><th>Max +</th><th>+MAE</th><th>-MAE</th><th>Guard</th><th>Pass</th><th>Median carb</th><th>P90 carb</th><th>Kcal MAE</th><th>Grounded</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </section>
  </main>
</body>
</html>`;
}

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  const index = (sorted.length - 1) * p;
  const lo = Math.floor(index);
  const hi = Math.ceil(index);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (index - lo);
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / Math.max(values.length, 1);
}

function shortLabel(label) {
  return String(label).replace(/^foodfinder_/, "").replace(/_/g, " ").slice(0, 16);
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;");
}

function splitCSVLine(line) {
  const out = [];
  let cur = "";
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === "\"") {
      quoted = !quoted;
    } else if (char === "," && !quoted) {
      out.push(cur);
      cur = "";
    } else {
      cur += char;
    }
  }
  out.push(cur);
  return out;
}

function cleanName(name) {
  return String(name || "").replace(/^"|"$/g, "").replace(/_/g, " ").trim();
}

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}
