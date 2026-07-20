import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

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
const maxCases = Number(env.FOODFINDER_MAX_CASES || 8);
const caseStart = Number(env.FOODFINDER_CASE_START || 0);
const sampleOffset = Number(env.FOODFINDER_SAMPLE_OFFSET || 0.35);
const composeWithAI = env.FOODFINDER_COMPOSE_WITH_AI !== "false";
const carbSafetyMode = env.FOODFINDER_CARB_SAFETY_MODE || "doseGuard";
const useOpenFoodFacts = env.FOODFINDER_USE_OPENFOODFACTS !== "false";
const concurrency = Math.max(1, Number(env.FOODFINDER_CONCURRENCY || 2));
const modalities = String(env.FOODFINDER_MODALITIES || "text,image,mixed,multi")
  .split(",")
  .map(item => item.trim())
  .filter(Boolean);
const runLabel = env.FOODFINDER_RUN_LABEL || "";
const historyPath = env.FOODFINDER_MODALITY_HISTORY_PATH || join(root, "modality_benchmark_history.json");
const printBrief = env.FOODFINDER_PRINT_BRIEF !== "false";

const cases = await selectFoodBDCases();
const allResults = {};
for (const modality of modalities) {
  allResults[modality] = await runCases(cases, modality);
}
const report = scoreReport(allResults, cases);
if (runLabel) {
  await writeRunArtifacts(report);
}
console.log(JSON.stringify(printBrief ? briefReport(report) : report, null, 2));

async function selectFoodBDCases() {
  const datasetDir = join(root, "foodbd");
  await ensureFoodBD(datasetDir);
  const nutritionRows = parseCSV(await readFile(join(datasetDir, "MealNutrition1837_All.csv"), "utf8"));
  const metadataRows = parseCSV(await readFile(join(datasetDir, "FoodBD_Meta_data.csv"), "utf8"));
  const metadata = new Map(metadataRows.slice(1).map(row => [
    row[0],
    {
      instances: splitInstances(row[1]),
      environment: row[2],
      split: row[4]
    }
  ]));

  const rows = nutritionRows.slice(1)
    .map(row => {
      const filename = row[0];
      const meta = metadata.get(filename);
      if (!meta) return null;
      return {
        id: filename.replace(/\.[^.]+$/, ""),
        filename,
        text: meta.instances.join(", "),
        instances: meta.instances,
        truth: {
          carbs: number(row[1]),
          protein: number(row[2]),
          fat: number(row[3]),
          fiber: number(row[4]),
          calories: number(row[5])
        },
        imagePath: join(datasetDir, "images", filename)
      };
    })
    .filter(Boolean)
    .filter(row => row.instances.length >= 2)
    .filter(row => /(rice|khichuri|biriyani|dal|vaji|fish|beef|chicken|ruti|shak|vegetable|curry|egg|potato|banana)/i.test(row.text));

  const selected = pickSpread(rows, Math.max(maxCases + caseStart, maxCases), sampleOffset)
    .slice(caseStart, caseStart + maxCases);
  await Promise.all(selected.map(row => ensureFoodBDImage(datasetDir, row.filename)));
  return selected;
}

async function ensureFoodBD(datasetDir) {
  await mkdir(datasetDir, { recursive: true });
  await mkdir(join(datasetDir, "images"), { recursive: true });
  const filesPath = join(datasetDir, "files.json");
  let files;
  if (existsSync(filesPath)) {
    files = JSON.parse(stripBOM(await readFile(filesPath, "utf8")));
  } else {
    const response = await fetch("https://data.mendeley.com/public-api/datasets/xh3ghf3jbg");
    if (!response.ok) throw new Error(`FoodBD metadata HTTP ${response.status}`);
    const json = await response.json();
    files = json.files || [];
    await writeFile(filesPath, JSON.stringify(files, null, 2), "utf8");
  }

  for (const filename of ["FoodBD_Meta_data.csv", "MealNutrition1837_All.csv"]) {
    const target = join(datasetDir, filename);
    if (existsSync(target)) continue;
    const file = files.find(item => item.filename === filename);
    if (!file?.content_details?.download_url) throw new Error(`Missing FoodBD file ${filename}`);
    const response = await fetch(file.content_details.download_url);
    if (!response.ok) throw new Error(`FoodBD ${filename} HTTP ${response.status}`);
    await writeFile(target, await response.text(), "utf8");
  }
}

async function ensureFoodBDImage(datasetDir, filename) {
  const target = join(datasetDir, "images", filename);
  if (existsSync(target)) return target;
  const files = JSON.parse(stripBOM(await readFile(join(datasetDir, "files.json"), "utf8")));
  const file = files.find(item => item.filename === filename);
  if (!file?.content_details?.download_url) throw new Error(`Missing FoodBD image ${filename}`);
  const response = await fetch(file.content_details.download_url);
  if (!response.ok) throw new Error(`FoodBD image ${filename} HTTP ${response.status}`);
  await writeFile(target, Buffer.from(await response.arrayBuffer()));
  return target;
}

async function runCases(selectedCases, modality) {
  const results = new Array(selectedCases.length);
  let nextIndex = 0;
  const workerCount = Math.min(concurrency, selectedCases.length);
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < selectedCases.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await runCase(selectedCases[index], modality);
    }
  }));
  return results;
}

async function runCase(test, modality) {
  const started = Date.now();
  const payload = await modalityPayload(test, modality);
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      provider,
      model,
      apiKey,
      usdaKey,
      language,
      useAI: Boolean(apiKey),
      useOpenFoodFacts,
      composeWithAI,
      carbSafetyMode,
      ...payload
    })
  });
  const json = await response.json();
  const pred = totals(json.final);
  return {
    id: test.id,
    text: test.text,
    modality,
    ok: response.ok,
    ms: Date.now() - started,
    truth: test.truth,
    pred,
    itemCount: json.final?.items?.length || 0,
    items: (json.final?.items || []).map(item => ({
      name: item.name,
      portion: item.portion,
      carbs: item.carbs,
      fat: item.fat,
      protein: item.protein,
      fiber: item.fiber,
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

async function modalityPayload(test, modality) {
  if (modality === "text") {
    return { mealText: test.text, images: [] };
  }
  if (modality === "image") {
    return { mealText: "", images: [await dataURL(test.imagePath)] };
  }
  if (modality === "multi") {
    const crops = await cropViews(test.imagePath);
    return {
      mealText: `Meal contains: ${test.text}. Estimate visible portions conservatively.`,
      images: [await dataURL(test.imagePath), ...(await Promise.all(crops.map(dataURL)))]
    };
  }
  return {
    mealText: `Meal contains: ${test.text}. Estimate visible portions conservatively.`,
    images: [await dataURL(test.imagePath)]
  };
}

async function cropViews(imagePath) {
  const dir = dirname(imagePath);
  const base = imagePath.replace(/\.[^.]+$/, "");
  const left = `${base}.left.jpg`;
  const right = `${base}.right.jpg`;
  if (!existsSync(left) || !existsSync(right)) {
    const script = [
      "from PIL import Image",
      "import sys",
      "src,left,right=sys.argv[1:4]",
      "im=Image.open(src).convert('RGB')",
      "w,h=im.size",
      "im.crop((0,0,int(w*0.62),h)).save(left, quality=88)",
      "im.crop((int(w*0.38),0,w,h)).save(right, quality=88)"
    ].join("\n");
    execFileSync("python", ["-c", script, resolve(imagePath), resolve(left), resolve(right)], { cwd: dir });
  }
  return [left, right];
}

async function dataURL(path) {
  const bytes = await readFile(path);
  const ext = path.toLowerCase().endsWith(".png") ? "png" : "jpeg";
  return `data:image/${ext};base64,${bytes.toString("base64")}`;
}

function scoreReport(allResults, selectedCases) {
  const reports = {};
  for (const [modality, results] of Object.entries(allResults)) {
    reports[modality] = score(results);
  }
  return {
    label: runLabel,
    dataset: {
      name: "FoodBD",
      source: "Mendeley Data 10.17632/xh3ghf3jbg.2",
      n: selectedCases.length,
      cases: selectedCases.map(item => ({ id: item.id, text: item.text, truth: item.truth }))
    },
    config: {
      endpoint,
      provider,
      model,
      maxCases,
      caseStart,
      sampleOffset,
      composeWithAI,
      carbSafetyMode,
      useOpenFoodFacts,
      concurrency,
      modalities,
      hasAIKey: Boolean(apiKey),
      hasUSDAKey: Boolean(usdaKey)
    },
    modalities: reports
  };
}

function score(results) {
  const keys = ["carbs", "protein", "fat", "fiber", "calories"];
  const keyStats = {};
  for (const key of keys) {
    const signed = results.map(row => row.pred[key] - row.truth[key]);
    const abs = signed.map(Math.abs);
    keyStats[key] = {
      signed: descriptive(signed),
      absolute: descriptive(abs),
      positiveMeanAbsoluteError: round1(mean(signed.filter(value => value > 0))),
      negativeMeanAbsoluteError: round1(mean(signed.filter(value => value < 0).map(Math.abs))),
      positiveCount: signed.filter(value => value > 0).length,
      negativeCount: signed.filter(value => value < 0).length,
      maxPositive: round1(Math.max(0, ...signed)),
      maxNegative: round1(Math.max(0, ...signed.map(value => -value)))
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
    carbSafetyPass: Math.max(0, ...carbSigned) <= 5 && mean(carbSigned.filter(value => value < 0).map(Math.abs)) < 5,
    metrics: keyStats,
    worstPositiveCarbs: [...results]
      .filter(row => row.pred.carbs - row.truth.carbs > 0)
      .sort((a, b) => (b.pred.carbs - b.truth.carbs) - (a.pred.carbs - a.truth.carbs))
      .slice(0, 5)
      .map(caseSummary),
    worstAbsoluteCarbs: [...results]
      .sort((a, b) => Math.abs(b.pred.carbs - b.truth.carbs) - Math.abs(a.pred.carbs - a.truth.carbs))
      .slice(0, 5)
      .map(caseSummary)
  };
}

function briefReport(report) {
  return {
    label: report.label,
    dataset: report.dataset,
    config: report.config,
    modalities: Object.fromEntries(Object.entries(report.modalities).map(([name, value]) => [
      name,
      {
        n: value.n,
        ok: value.ok,
        aiPrompts: value.aiPrompts,
        carbs: value.metrics.carbs,
        calories: value.metrics.calories,
        groundedItemRate: value.groundedItemRate,
        carbSafetyPass: value.carbSafetyPass,
        worstPositiveCarbs: value.worstPositiveCarbs,
        worstAbsoluteCarbs: value.worstAbsoluteCarbs
      }
    ]))
  };
}

async function writeRunArtifacts(report) {
  let history = [];
  if (existsSync(historyPath)) {
    try {
      history = JSON.parse(stripBOM(await readFile(historyPath, "utf8")));
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
    sum.fiber += Number(item.fiber) || 0;
    return sum;
  }, { calories: 0, fat: 0, carbs: 0, protein: 0, fiber: 0 });
}

function caseSummary(row) {
  return {
    id: row.id,
    text: row.text,
    signedCarbError: round1(row.pred.carbs - row.truth.carbs),
    carbAbsError: round1(Math.abs(row.pred.carbs - row.truth.carbs)),
    predCarbs: round1(row.pred.carbs),
    trueCarbs: round1(row.truth.carbs),
    predCalories: round1(row.pred.calories),
    trueCalories: round1(row.truth.calories),
    grounded: `${row.items.filter(item => item.source && item.source !== "aiEstimate").length}/${row.items.length}`
  };
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

function pickSpread(rows, count, offset = 0.35) {
  if (rows.length <= count) return rows;
  const selected = [];
  const seen = new Set();
  const step = Math.max(1, Math.floor(rows.length / count));
  for (let index = Math.floor(step * offset); selected.length < count && index < rows.length; index += step) {
    const row = rows[index];
    const signature = row.text;
    if (seen.has(signature)) continue;
    selected.push(row);
    seen.add(signature);
  }
  return selected;
}

function splitInstances(value) {
  return String(value || "")
    .replace(/^"|"$/g, "")
    .split(",")
    .map(item => item.trim())
    .filter(Boolean);
}

function parseCSV(text) {
  return text.trim().split(/\r?\n/).map(splitCSVLine);
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
  return out.map(value => value.replace(/^"|"$/g, ""));
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
  return Number(String(value || "0").replace(",", ".")) || 0;
}

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

function stripBOM(value) {
  return String(value || "").replace(/^\uFEFF/, "");
}
