import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const port = Number(process.env.PORT || 8787);
const maxImages = 6;

createServer(async (req, res) => {
  try {
    if (req.method === "GET") {
      await serveStatic(req, res);
      return;
    }

    if (req.method === "POST" && req.url === "/api/analyze") {
      const body = await readJSON(req);
      const result = await analyzeMeal(body);
      sendJSON(res, 200, result);
      return;
    }

    sendJSON(res, 404, { error: "Not found" });
  } catch (error) {
    sendJSON(res, 500, {
      error: error instanceof Error ? error.message : String(error)
    });
  }
}).listen(port, () => {
  console.log(`FoodFinder Agent Lab: http://localhost:${port}`);
});

async function serveStatic(req, res) {
  const url = new URL(req.url || "/", `http://localhost:${port}`);
  const pathname = url.pathname === "/" ? "/index.html" : url.pathname;
  const file = join(root, pathname.replace(/^\/+/, ""));
  const data = await readFile(file);
  const type = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8"
  }[extname(file)] || "application/octet-stream";
  res.writeHead(200, { "content-type": type });
  res.end(data);
}

function readJSON(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", chunk => {
      raw += chunk;
      if (raw.length > 15_000_000) {
        reject(new Error("Request too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      try {
        resolve(raw ? JSON.parse(raw) : {});
      } catch {
        reject(new Error("Invalid JSON"));
      }
    });
    req.on("error", reject);
  });
}

function sendJSON(res, status, payload) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  res.end(JSON.stringify(payload, null, 2));
}

async function analyzeMeal(input) {
  const mealText = String(input.mealText || "").trim();
  const provider = input.provider === "gemini" ? "gemini" : "openai";
  const apiKey = String(input.apiKey || "").trim();
  const model = String(input.model || (provider === "gemini" ? "gemini-1.5-flash" : "gpt-4o-mini")).trim();
  const usdaKey = String(input.usdaKey || "").trim();
  const language = String(input.language || "nl").trim();
  const useAI = input.useAI !== false && apiKey.length > 0;
  const images = Array.isArray(input.images) ? input.images.slice(0, maxImages) : [];
  const toolLog = [];

  if (!mealText && images.length === 0) {
    throw new Error("Add a meal description or at least one image.");
  }

  let intents;
  if (useAI) {
    toolLog.push({ type: "ai", name: "parse_ingredient_intents", status: "started", provider, model });
    try {
      intents = await parseIngredientIntents({ provider, apiKey, model, mealText, images, language });
      toolLog.push({ type: "ai", name: "parse_ingredient_intents", status: "ok", output: intents });
    } catch (error) {
      toolLog.push({ type: "ai", name: "parse_ingredient_intents", status: "failed", error: error.message });
      intents = fallbackIntents(mealText);
    }
  } else {
    toolLog.push({ type: "local", name: "fallback_intent_parser", status: "ok" });
    intents = fallbackIntents(mealText);
  }

  const ingredients = normalizeIntents(intents, mealText);
  const enriched = await Promise.all(ingredients.map(async ingredient => {
    const query = [ingredient.name, ingredient.brand].filter(Boolean).join(" ");
    const calls = [
      callTool(toolLog, "openfoodfacts.search", query, () => searchOpenFoodFacts(query))
    ];
    if (usdaKey) {
      calls.push(callTool(toolLog, "usda.search", query, () => searchUSDA(query, usdaKey)));
    }
    const nested = await Promise.all(calls);
    const matches = nested.flat().filter(Boolean);
    const selected = chooseBestMatch(ingredient, matches) || heuristicEstimate(ingredient);
    return { ...ingredient, selected, alternateMatches: matches.slice(0, 8) };
  }));

  let final;
  if (useAI) {
    toolLog.push({ type: "ai", name: "compose_verified_meal_json", status: "started", provider, model });
    try {
      final = await composeFinalMeal({ provider, apiKey, model, mealText, images, language, enriched });
      toolLog.push({ type: "ai", name: "compose_verified_meal_json", status: "ok" });
    } catch (error) {
      toolLog.push({ type: "ai", name: "compose_verified_meal_json", status: "failed", error: error.message });
      final = fallbackFinalMeal(mealText, enriched);
    }
  } else {
    final = fallbackFinalMeal(mealText, enriched);
  }

  return {
    mealText,
    provider,
    model,
    maxImages,
    intents: ingredients,
    enriched,
    final,
    toolLog
  };
}

async function callTool(log, name, query, fn) {
  const started = Date.now();
  log.push({ type: "tool", name, query, status: "started" });
  try {
    const result = await fn();
    log.push({ type: "tool", name, query, status: "ok", ms: Date.now() - started, count: result.length });
    return result;
  } catch (error) {
    log.push({ type: "tool", name, query, status: "failed", ms: Date.now() - started, error: error.message });
    return [];
  }
}

async function parseIngredientIntents(args) {
  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["mealName", "mealPortion", "ingredients"],
    properties: {
      mealName: { type: "string" },
      mealPortion: { type: "string" },
      ingredients: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "portion", "brand"],
          properties: {
            name: { type: "string" },
            portion: { type: "string" },
            brand: { type: "string" }
          }
        }
      }
    }
  };

  const system = [
    "You parse meals for a Type 1 Diabetes nutrition lookup pipeline.",
    `Return ingredient intents in ${args.language}.`,
    "Do not estimate macros. Only identify likely ingredients and portions.",
    "For compound meals, split important carb/fat/protein sources into separate ingredients."
  ].join("\n");
  const user = args.mealText || "Analyze the attached meal photo(s).";

  return callProviderJSON({ ...args, system, user, schema, schemaName: "foodfinder_intents" });
}

async function composeFinalMeal(args) {
  const schema = {
    type: "object",
    additionalProperties: false,
    required: ["mealName", "mealPortion", "confidence", "items"],
    properties: {
      mealName: { type: "string" },
      mealPortion: { type: "string" },
      confidence: { type: "number" },
      items: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          required: ["name", "portion", "carbs", "fat", "protein", "fiber", "calories", "source"],
          properties: {
            name: { type: "string" },
            portion: { type: "string" },
            carbs: { type: "number" },
            fat: { type: "number" },
            protein: { type: "number" },
            fiber: { type: "number" },
            calories: { type: "number" },
            source: { type: "string" }
          }
        }
      }
    }
  };
  const toolSummary = args.enriched.map(item => ({
    name: item.name,
    portion: item.portion,
    selected: item.selected,
    alternates: item.alternateMatches.slice(0, 3)
  }));
  const system = [
    "You finalize a verified FoodFinder meal JSON for a Type 1 Diabetes app.",
    `Write names and portions in ${args.language}.`,
    "Use selected source data when it matches the ingredient.",
    "Only estimate when no source match exists. Avoid 0 carbs for pasta, rice, bread, pizza, potato, fruit, dessert, or noodles unless portion is negligible.",
    "Return JSON only."
  ].join("\n");
  const user = [
    `User meal text: ${args.mealText || "(photo only)"}`,
    "Ingredient intents and tool results:",
    JSON.stringify(toolSummary, null, 2)
  ].join("\n\n");

  return callProviderJSON({ ...args, system, user, schema, schemaName: "foodfinder_final" });
}

async function callProviderJSON(args) {
  if (args.provider === "gemini") {
    return callGeminiJSON(args);
  }
  return callOpenAIJSON(args);
}

async function callOpenAIJSON({ apiKey, model, system, user, images, schema, schemaName }) {
  const content = [{ type: "text", text: user }];
  for (const dataUrl of images || []) {
    content.push({ type: "image_url", image_url: { url: dataUrl, detail: "low" } });
  }
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "authorization": `Bearer ${apiKey}`,
      "content-type": "application/json"
    },
    body: JSON.stringify({
      model,
      temperature: 0.1,
      messages: [
        { role: "system", content: system },
        { role: "user", content }
      ],
      response_format: {
        type: "json_schema",
        json_schema: { name: schemaName, strict: true, schema }
      }
    })
  });
  const json = await response.json();
  if (!response.ok) {
    throw new Error(json.error?.message || `OpenAI HTTP ${response.status}`);
  }
  return parseJSONText(json.choices?.[0]?.message?.content);
}

async function callGeminiJSON({ apiKey, model, system, user, images }) {
  const parts = [{ text: `${system}\n\n${user}` }];
  for (const dataUrl of images || []) {
    const parsed = parseDataURL(dataUrl);
    if (parsed) {
      parts.push({ inlineData: { mimeType: parsed.mimeType, data: parsed.base64 } });
    }
  }
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts }],
      generationConfig: {
        temperature: 0.1,
        responseMimeType: "application/json"
      }
    })
  });
  const json = await response.json();
  if (!response.ok) {
    throw new Error(json.error?.message || `Gemini HTTP ${response.status}`);
  }
  const text = json.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("\n");
  return parseJSONText(text);
}

function fallbackIntents(mealText) {
  const pieces = mealText
    .split(/\s*(?:,|\+| and | en | met | with | e )\s*/i)
    .map(x => x.trim())
    .filter(Boolean);
  return {
    mealName: mealText || "Meal",
    mealPortion: "",
    ingredients: pieces.length ? pieces.map(name => ({ name, portion: "", brand: "" })) : []
  };
}

function normalizeIntents(intents, mealText) {
  const ingredients = Array.isArray(intents?.ingredients) ? intents.ingredients : [];
  if (!ingredients.length && mealText) {
    return fallbackIntents(mealText).ingredients;
  }
  return ingredients
    .map(item => ({
      name: String(item.name || "").trim(),
      portion: String(item.portion || "").trim(),
      brand: String(item.brand || "").trim()
    }))
    .filter(item => item.name);
}

function fallbackFinalMeal(mealText, enriched) {
  const items = enriched.map(item => {
    const selected = item.selected;
    return {
      name: item.name,
      portion: item.portion || selected?.portion || "1 serving",
      carbs: round1(selected?.carbs || 0),
      fat: round1(selected?.fat || 0),
      protein: round1(selected?.protein || 0),
      fiber: round1(selected?.fiber || 0),
      calories: round1(selected?.calories || 0),
      source: selected?.sourceID || "aiEstimate"
    };
  });
  const avgConfidence = enriched.length
    ? enriched.reduce((sum, item) => sum + (item.selected?.verifiedScore || 0.35), 0) / enriched.length
    : 0.1;
  return {
    mealName: mealText || items.map(item => item.name).join(", ") || "Meal",
    mealPortion: "",
    confidence: round2(avgConfidence),
    items
  };
}

function heuristicEstimate(ingredient) {
  const text = `${ingredient.name} ${ingredient.portion}`.toLowerCase();
  const estimate = (name, portion, carbs, fat, protein, fiber, calories) => ({
    sourceID: "aiEstimate",
    name,
    brand: "",
    portion,
    portionGrams: gramsFromPortion(portion),
    carbs,
    fat,
    protein,
    fiber,
    calories,
    sourceURL: "",
    verifiedScore: 0.35,
    sourceVerified: false,
    imageURL: "",
    matchScore: 0.35
  });
  if (/(spaghetti|pasta|noodle)/i.test(text)) {
    return estimate("Cooked pasta estimate", ingredient.portion || "250 g cooked", 75, 2, 13, 4, 395);
  }
  if (/(rice|rijst|risotto)/i.test(text)) {
    return estimate("Cooked rice estimate", ingredient.portion || "180 g cooked", 50, 1, 5, 1, 240);
  }
  if (/(pizza)/i.test(text)) {
    return estimate("Pizza estimate", ingredient.portion || "1 pizza", 90, 30, 35, 4, 800);
  }
  if (/(banana|banaan)/i.test(text)) {
    return estimate("Banana estimate", ingredient.portion || "1 medium banana (118 g)", 27, 0.4, 1.3, 3.1, 105);
  }
  if (/(bread|brood|toast|bagel|bun)/i.test(text)) {
    return estimate("Bread estimate", ingredient.portion || "1 serving", 30, 2, 6, 2, 160);
  }
  if (/(potato|aardappel|fries|friet)/i.test(text)) {
    return estimate("Potato estimate", ingredient.portion || "200 g", 40, 0.2, 4, 4, 180);
  }
  return null;
}

async function searchOpenFoodFacts(query) {
  const url = new URL("https://world.openfoodfacts.org/api/v2/search");
  url.searchParams.set("search_terms", query);
  url.searchParams.set("fields", "code,product_name,brands,nutriments,serving_size,serving_quantity,nutrition_data_completeness,image_url,url");
  url.searchParams.set("page_size", "6");
  url.searchParams.set("json", "1");
  const response = await fetch(url, {
    headers: {
      "accept": "application/json",
      "user-agent": "Trio-FoodFinder-AgentLab/0.1"
    }
  });
  if (!response.ok) {
    throw new Error(`OpenFoodFacts HTTP ${response.status}`);
  }
  const json = await response.json();
  return (json.products || []).map(product => offResult(product, query)).filter(Boolean);
}

function offResult(product, fallbackName) {
  const nutriments = product.nutriments || {};
  const name = string(product.product_name, fallbackName);
  if (!name || !Object.keys(nutriments).length) return null;
  const code = string(product.code, "");
  const serving = string(product.serving_size, "100 g");
  const completeness = clamp(number(product.nutrition_data_completeness, 0.35), 0.35, 1);
  return {
    sourceID: "openFoodFacts",
    name,
    brand: string(product.brands, ""),
    portion: serving,
    portionGrams: gramsFromPortion(serving) || number(product.serving_quantity, null),
    carbs: nutrient(nutriments, ["carbohydrates_serving", "carbohydrates_100g"]),
    fat: nutrient(nutriments, ["fat_serving", "fat_100g"]),
    protein: nutrient(nutriments, ["proteins_serving", "proteins_100g"]),
    fiber: nutrient(nutriments, ["fiber_serving", "fiber_100g"]),
    calories: nutrient(nutriments, ["energy-kcal_serving", "energy-kcal_100g"]),
    sourceURL: string(product.url, code ? `https://world.openfoodfacts.org/product/${code}` : ""),
    verifiedScore: completeness,
    sourceVerified: completeness >= 0.6,
    imageURL: string(product.image_url, "")
  };
}

async function searchUSDA(query, apiKey) {
  const url = new URL("https://api.nal.usda.gov/fdc/v1/foods/search");
  url.searchParams.set("query", query);
  url.searchParams.set("pageSize", "6");
  url.searchParams.set("api_key", apiKey);
  const response = await fetch(url, { headers: { "accept": "application/json" } });
  if (!response.ok) {
    throw new Error(`USDA HTTP ${response.status}`);
  }
  const json = await response.json();
  return (json.foods || []).map(usdaResult).filter(Boolean);
}

function usdaResult(food) {
  const nutrients = food.foodNutrients || [];
  const grams = number(food.servingSize, 100) || 100;
  const unit = string(food.servingSizeUnit, "g");
  const score = /foundation/i.test(string(food.dataType, "")) ? 0.9 : 0.78;
  return {
    sourceID: "usda",
    name: string(food.description, ""),
    brand: string(food.brandOwner, ""),
    portion: food.servingSize ? `${Math.round(grams)} ${unit}` : "100 g",
    portionGrams: grams,
    carbs: usdaNutrient(nutrients, ["Carbohydrate, by difference", "Carbohydrate"]),
    fat: usdaNutrient(nutrients, ["Total lipid (fat)", "Total Fat"]),
    protein: usdaNutrient(nutrients, ["Protein"]),
    fiber: usdaNutrient(nutrients, ["Fiber, total dietary", "Fiber"]),
    calories: usdaNutrient(nutrients, ["Energy"]),
    sourceURL: food.fdcId ? `https://fdc.nal.usda.gov/fdc-app.html#/food-details/${food.fdcId}/nutrients` : "",
    verifiedScore: score,
    sourceVerified: true,
    imageURL: ""
  };
}

function chooseBestMatch(ingredient, matches) {
  if (!matches.length) return null;
  return matches
    .map(match => ({
      ...match,
      matchScore: round2(match.verifiedScore * nameMatchScore(ingredient.name, match.name))
    }))
    .filter(match => match.matchScore >= 0.3)
    .sort((a, b) => b.matchScore - a.matchScore || sourceRank(a.sourceID) - sourceRank(b.sourceID))[0] || null;
}

function sourceRank(sourceID) {
  if (sourceID === "openFoodFacts") return 0;
  if (sourceID === "usda") return 1;
  return 2;
}

function nameMatchScore(query, candidate) {
  const q = tokens(query);
  const c = tokens(candidate);
  if (!q.size || !c.size) return 0;
  let overlap = 0;
  for (const token of q) {
    if (c.has(token)) overlap += 1;
  }
  if (!overlap) return 0.25;
  const union = new Set([...q, ...c]).size;
  return Math.min(1, Math.max(overlap / q.size, overlap / union));
}

function tokens(text) {
  const stop = new Set(["the", "and", "with", "for", "een", "het", "de", "met", "van", "zonder", "portion", "serving", "plate", "bowl", "cooked", "raw"]);
  return new Set(String(text).toLowerCase().split(/[^a-z0-9]+/i).filter(x => x.length > 2 && !stop.has(x)));
}

function nutrient(nutriments, names) {
  for (const name of names) {
    const value = number(nutriments[name], null);
    if (value !== null && Number.isFinite(value)) return value;
  }
  return 0;
}

function usdaNutrient(nutrients, names) {
  const lowered = names.map(name => name.toLowerCase());
  for (const nutrient of nutrients) {
    const name = string(nutrient.nutrientName || nutrient.name, "").toLowerCase();
    if (lowered.some(target => name.includes(target))) {
      return number(nutrient.value || nutrient.amount, 0);
    }
  }
  return 0;
}

function parseJSONText(text) {
  if (!text) throw new Error("Provider returned an empty response");
  try {
    return JSON.parse(text);
  } catch {
    const start = text.indexOf("{");
    const end = text.lastIndexOf("}");
    if (start >= 0 && end > start) {
      return JSON.parse(text.slice(start, end + 1));
    }
    throw new Error("Provider did not return valid JSON");
  }
}

function parseDataURL(dataUrl) {
  const match = /^data:([^;,]+);base64,(.+)$/i.exec(String(dataUrl));
  if (!match) return null;
  return { mimeType: match[1], base64: match[2] };
}

function gramsFromPortion(portion) {
  const match = /(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|milliliter|milliliters)\b/i.exec(String(portion));
  return match ? Number(match[1].replace(",", ".")) : null;
}

function string(value, fallback) {
  if (value === null || value === undefined) return fallback;
  const text = String(value).trim();
  return text || fallback;
}

function number(value, fallback = 0) {
  const numeric = Number(String(value ?? "").replace(",", "."));
  return Number.isFinite(numeric) ? numeric : fallback;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

function round2(value) {
  return Math.round((Number(value) || 0) * 100) / 100;
}
