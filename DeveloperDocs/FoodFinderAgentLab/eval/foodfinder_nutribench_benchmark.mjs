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
const maxCases = Number(env.FOODFINDER_MAX_CASES || 50);
const caseSetSize = Number(env.FOODFINDER_CASE_SET_SIZE || Math.max(150, maxCases * 3));
const sampleOffset = Number(env.FOODFINDER_SAMPLE_OFFSET || 0.33);
const configName = env.FOODFINDER_NUTRIBENCH_CONFIG || "v2";
const split = env.FOODFINDER_NUTRIBENCH_SPLIT || "train";
const servingTypes = splitList(env.FOODFINDER_NUTRIBENCH_SERVING_TYPES || "");
const countries = splitList(env.FOODFINDER_NUTRIBENCH_COUNTRIES || "");
const hardOnly = env.FOODFINDER_NUTRIBENCH_HARD_ONLY === "true";
const composeWithAI = env.FOODFINDER_COMPOSE_WITH_AI === "true";
const carbSafetyMode = env.FOODFINDER_CARB_SAFETY_MODE || "doseGuard";
const useOpenFoodFacts = env.FOODFINDER_USE_OPENFOODFACTS !== "false";
const concurrency = Math.max(1, Number(env.FOODFINDER_CONCURRENCY || 4));
const runLabel = env.FOODFINDER_RUN_LABEL || "";
const historyPath = env.FOODFINDER_NUTRIBENCH_HISTORY_PATH || join(root, "nutribench_benchmark_history.json");
const printBrief = env.FOODFINDER_PRINT_BRIEF !== "false";

const cases = await selectCases();
const results = await runCases(cases);
const report = scoreReport(results, cases);
if (runLabel) {
  await writeRunArtifacts(report);
}
console.log(JSON.stringify(printBrief ? briefReport(report) : report, null, 2));

async function selectCases() {
  const pool = await fetchNutriBenchPool();
  const filtered = pool
    .map(({ row_idx, row }) => ({
      id: `nutribench_${configName}_${split}_${row_idx}`,
      text: decodeMojibake(String(row.meal_description || "")).trim(),
      country: row.country || "",
      servingType: row.serving_type || "",
      truth: {
        carbs: number(row.carb),
        fat: number(row.fat),
        protein: number(row.protein),
        calories: number(row.energy)
      }
    }))
    .filter(item => item.text && item.truth.calories > 0)
    .filter(item => servingTypes.length === 0 || servingTypes.includes(String(item.servingType).toLowerCase()))
    .filter(item => countries.length === 0 || countries.includes(String(item.country).toLowerCase()))
    .filter(item => !hardOnly || isHardMealDescription(item.text));

  return pickSpread(filtered, Math.min(maxCases, filtered.length), sampleOffset);
}

async function fetchNutriBenchPool() {
  const metaURL = "https://huggingface.co/api/datasets/dongx1997/NutriBench";
  const meta = await fetchJSON(metaURL);
  const total = meta.cardData?.dataset_info
    ?.find(item => item.config_name === configName)
    ?.splits
    ?.find(item => item.name === split)
    ?.num_examples || 15617;

  const pageCount = Math.max(1, Math.ceil(caseSetSize / 100));
  const pages = [];
  const maxOffset = Math.max(0, total - 100);
  for (let index = 0; index < pageCount; index += 1) {
    const fraction = pageCount === 1 ? sampleOffset : (index + sampleOffset) / pageCount;
    const offset = Math.max(0, Math.min(maxOffset, Math.floor(maxOffset * fraction)));
    pages.push(offset);
  }

  const rows = [];
  for (const offset of [...new Set(pages)]) {
    const url = new URL("https://datasets-server.huggingface.co/rows");
    url.searchParams.set("dataset", "dongx1997/NutriBench");
    url.searchParams.set("config", configName);
    url.searchParams.set("split", split);
    url.searchParams.set("offset", String(offset));
    url.searchParams.set("length", "100");
    const page = await fetchJSON(url);
    rows.push(...(page.rows || []));
  }
  return rows;
}

async function fetchJSON(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${url}`);
  }
  return response.json();
}

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
    country: test.country,
    servingType: test.servingType,
    ok: response.ok,
    ms: Date.now() - started,
    truth: test.truth,
    pred: totals(json.final),
    itemCount: json.final?.items?.length || 0,
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

function scoreReport(results, selectedCases) {
  return {
    label: runLabel,
    dataset: {
      name: "NutriBench",
      source: "Hugging Face dongx1997/NutriBench",
      config: configName,
      split,
      n: selectedCases.length,
      cases: selectedCases.map(item => ({
        id: item.id,
        text: item.text,
        country: item.country,
        servingType: item.servingType,
        truth: item.truth
      }))
    },
    config: {
      endpoint,
      provider,
      model,
      maxCases,
      caseSetSize,
      sampleOffset,
      servingTypes,
      countries,
      hardOnly,
      composeWithAI,
      carbSafetyMode,
      useOpenFoodFacts,
      concurrency,
      hasAIKey: Boolean(apiKey),
      hasUSDAKey: Boolean(usdaKey)
    },
    score: score(results)
  };
}

function score(results) {
  const keys = ["carbs", "protein", "fat", "calories"];
  const keyStats = {};
  for (const key of keys) {
    const signed = results.map(row => row.pred[key] - row.truth[key]);
    const abs = signed.map(Math.abs);
    const positive = signed.filter(value => value > 0);
    const negative = signed.filter(value => value < 0).map(value => Math.abs(value));
    keyStats[key] = {
      signed: descriptive(signed),
      absolute: descriptive(abs),
      positiveMeanAbsoluteError: round1(mean(positive)),
      negativeMeanAbsoluteError: round1(mean(negative)),
      positiveCount: positive.length,
      negativeCount: negative.length,
      maxPositive: round1(Math.max(0, ...positive)),
      maxNegative: round1(Math.max(0, ...negative))
    };
  }
  const carbSigned = results.map(row => row.pred.carbs - row.truth.carbs);
  return {
    n: results.length,
    ok: results.filter(row => row.ok).length,
    aiPrompts: results.reduce((sum, row) => sum + row.aiPrompts, 0),
    ms: descriptive(results.map(row => row.ms)),
    groundedItemRate: round1(results.reduce((sum, row) => {
      const grounded = row.items.filter(item => item.source && item.source !== "aiEstimate").length;
      return sum + (row.items.length ? grounded / row.items.length : 0);
    }, 0) / Math.max(results.length, 1) * 100),
    insulinDoseAtIC10: {
      meanAbsoluteUnits: round2(keyStats.carbs.absolute.mean / 10),
      positiveMeanAbsoluteUnits: round2(keyStats.carbs.positiveMeanAbsoluteError / 10),
      maxPositiveUnits: round2(keyStats.carbs.maxPositive / 10),
      p95AbsoluteUnits: round2(keyStats.carbs.absolute.p95 / 10)
    },
    metrics: keyStats,
    worstPositiveCarbs: [...results]
      .filter(row => row.pred.carbs - row.truth.carbs > 0)
      .sort((a, b) => (b.pred.carbs - b.truth.carbs) - (a.pred.carbs - a.truth.carbs))
      .slice(0, 8)
      .map(caseSummary),
    worstAbsoluteCarbs: [...results]
      .sort((a, b) => Math.abs(b.pred.carbs - b.truth.carbs) - Math.abs(a.pred.carbs - a.truth.carbs))
      .slice(0, 8)
      .map(caseSummary)
  };
}

function briefReport(report) {
  return {
    label: report.label,
    dataset: report.dataset,
    config: report.config,
    score: {
      n: report.score.n,
      ok: report.score.ok,
      aiPrompts: report.score.aiPrompts,
      carbs: report.score.metrics.carbs,
      calories: report.score.metrics.calories,
      insulinDoseAtIC10: report.score.insulinDoseAtIC10,
      groundedItemRate: report.score.groundedItemRate,
      worstPositiveCarbs: report.score.worstPositiveCarbs,
      worstAbsoluteCarbs: report.score.worstAbsoluteCarbs
    }
  };
}

async function writeRunArtifacts(report) {
  await mkdir(root, { recursive: true });
  let history = [];
  if (existsSync(historyPath)) {
    try {
      history = JSON.parse(await readFile(historyPath, "utf8"));
    } catch {
      history = [];
    }
  }
  const existing = history.findIndex(item => item.label === runLabel);
  if (existing >= 0) {
    history[existing] = report;
  } else {
    history.push(report);
  }
  await writeFile(historyPath, JSON.stringify(history, null, 2), "utf8");
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

function caseSummary(row) {
  return {
    id: row.id,
    country: row.country,
    servingType: row.servingType,
    text: row.text,
    signedCarbError: round1(row.pred.carbs - row.truth.carbs),
    carbAbsError: round1(Math.abs(row.pred.carbs - row.truth.carbs)),
    predCarbs: round1(row.pred.carbs),
    trueCarbs: round1(row.truth.carbs),
    predCalories: round1(row.pred.calories),
    trueCalories: round1(row.truth.calories),
    grounded: `${row.items.filter(item => item.source && item.source !== "aiEstimate").length}/${row.items.length}`,
    items: row.items.map(item => `${item.name} (${item.portion}, ${item.source})`)
  };
}

function isHardMealDescription(text) {
  return /\b(sauce|curry|stew|soup|fried|stir[-\s]?fried|mixed|rice|pasta|noodle|bread|sandwich|taco|pizza|porridge|dumpling|fritter|beans|lentil|dal|dhal|salad|dressing|gravy|dessert|cake|pie|pancake|waffle|syrup|cream)\b/i.test(text);
}

function pickSpread(rows, count, offset = 0.33) {
  if (rows.length <= count) return rows;
  const selected = [];
  const seen = new Set();
  const step = Math.max(1, Math.floor(rows.length / count));
  for (let index = Math.floor(step * offset); selected.length < count && index < rows.length; index += step) {
    const row = rows[index];
    const signature = row.text.toLowerCase().replace(/\d+(?:\.\d+)?\s*(?:g|grams|ml|cups?|tbsp|tsp|ounces?|oz)/g, "");
    if (seen.has(signature)) continue;
    selected.push(row);
    seen.add(signature);
  }
  return selected;
}

function descriptive(values) {
  const sorted = values
    .map(Number)
    .filter(Number.isFinite)
    .sort((a, b) => a - b);
  return {
    min: round1(sorted[0] || 0),
    p10: round1(percentile(sorted, 0.1)),
    p25: round1(percentile(sorted, 0.25)),
    median: round1(percentile(sorted, 0.5)),
    p75: round1(percentile(sorted, 0.75)),
    p90: round1(percentile(sorted, 0.9)),
    p95: round1(percentile(sorted, 0.95)),
    max: round1(sorted[sorted.length - 1] || 0),
    mean: round1(mean(sorted))
  };
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

function number(value) {
  return Number(value) || 0;
}

function splitList(value) {
  return String(value || "")
    .split(",")
    .map(item => item.trim().toLowerCase())
    .filter(Boolean);
}

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

function round2(value) {
  return Math.round((Number(value) || 0) * 100) / 100;
}

function decodeMojibake(value) {
  return value
    .replaceAll("â", "'")
    .replaceAll("â", "\"")
    .replaceAll("â", "\"")
    .replaceAll("â", "-")
    .replaceAll("Â", "");
}
