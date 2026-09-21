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
  const nutritionixAppId = String(input.nutritionixAppId || "").trim();
  const nutritionixApiKey = String(input.nutritionixApiKey || "").trim();
  const restaurantName = String(input.restaurantName || input.locationContext?.restaurantName || "").trim();
  const language = String(input.language || "nl").trim();
  const useAI = input.useAI !== false && apiKey.length > 0;
  const useOpenFoodFacts = input.useOpenFoodFacts !== false;
  const composeWithAI = input.composeWithAI !== false;
  const carbSafetyMode = input.carbSafetyMode === "balanced" ? "balanced" : "doseGuard";
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

  const ingredients = applyUncertainImagePortionGuard(normalizeIntents(intents, mealText), { mealText, images });
  const enriched = await Promise.all(ingredients.map(async ingredient => {
    const query = [ingredient.name, ingredient.brand].filter(Boolean).join(" ");
    const calls = [];
    if (restaurantName && nutritionixAppId && nutritionixApiKey) {
      calls.push(callTool(
        toolLog,
        "restaurantMenu.search",
        `${restaurantName} ${query}`,
        () => searchNutritionixRestaurant(query, restaurantName, nutritionixAppId, nutritionixApiKey)
      ));
    }
    if (useOpenFoodFacts) {
      calls.push(callTool(toolLog, "openfoodfacts.search", query, () => searchOpenFoodFacts(query)));
    }
    if (usdaKey) {
      calls.push(callTool(toolLog, "usda.search", query, () => searchUSDA(query, usdaKey)));
    }
    const nested = await Promise.all(calls);
    const matches = nested.flat().filter(Boolean);
    const selected = chooseGroundedMatch(ingredient, matches, carbSafetyMode);
    return { ...ingredient, selected, alternateMatches: matches.slice(0, 8) };
  }));

  let final;
  if (useAI && composeWithAI) {
    toolLog.push({ type: "ai", name: "compose_verified_meal_json", status: "started", provider, model });
    try {
      final = await composeFinalMeal({ provider, apiKey, model, mealText, images, language, enriched });
      if (!isUsableFinalMeal(final, enriched)) {
        throw new Error("Provider returned an incomplete meal item list.");
      }
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
    useOpenFoodFacts,
    restaurantName,
    carbSafetyMode,
    intents: ingredients,
    enriched,
    final,
    toolLog
  };
}

function chooseGroundedMatch(ingredient, matches, carbSafetyMode = "doseGuard") {
  const selected = chooseBestMatch(ingredient, matches);
  const heuristic = heuristicEstimate(ingredient);
  if (heuristic?.sourceID === "localReference" && /^(Trace seasoning|Water)$/i.test(heuristic.name || "")) {
    return heuristic;
  }
  if (!selected) return heuristic;
  if (carbSafetyMode === "doseGuard" && heuristic && selected.matchScore < 0.55) {
    return heuristic;
  }
  if (heuristic && shouldPreferReferenceEstimate(ingredient, selected, heuristic)) {
    return heuristic;
  }
  return normalizeMacroEnergy(selected);
}

function shouldPreferReferenceEstimate(ingredient, selected, heuristic = null) {
  const text = `${ingredient.name} ${ingredient.portion}`.toLowerCase();
  const per100 = per100FromMatch(selected);
  const profile = foodProfileFor(text);
  const heuristicPer100 = heuristic ? per100FromMatch(heuristic) : null;
  const macroSum = (selected.carbs || 0) + (selected.fat || 0) + (selected.protein || 0);
  const atwater = per100.carbs * 4 + per100.protein * 4 + per100.fat * 9;

  if ((selected.calories || 0) === 0 && macroSum > 0) return true;
  if (atwater > 0 && per100.calories > 0 && Math.abs(per100.calories - atwater) / atwater > 0.55) return true;
  if (hasUnrequestedPrepMismatch(text, selected.name)) return true;
  if (hasCompetingFoodCategory(text, selected.name)) return true;
  if (hasUnrequestedFoodForm(text, selected.name)) return true;
  if (isBroadFoodCategoryQuery(text, selected.name)) return true;
  if (profile && isOutsideFoodProfile(profile, per100)) return true;
  if (profile?.expectsCarbs && per100.carbs < 1 && per100.calories < 20) return true;
  if (
    heuristicPer100 &&
    profile?.id === "starch" &&
    !/\b(raw|dry|dried|uncooked|ongekookt|rauw|flour|meel|powder)\b/i.test(text) &&
    per100.carbs > 45 &&
    heuristicPer100.carbs > 0 &&
    heuristicPer100.carbs < per100.carbs * 0.6
  ) {
    return true;
  }
  if (
    heuristicPer100 &&
    /\b(sausage|worst)\b/i.test(text) &&
    per100.carbs > Math.max(8, heuristicPer100.carbs * 1.8)
  ) {
    return true;
  }
  if (
    heuristicPer100 &&
    /\b(achar|pickle|chutney|relish)\b/i.test(text) &&
    (per100.carbs > 40 || per100.calories > 250)
  ) {
    return true;
  }
  return false;
}

function normalizeMacroEnergy(selected) {
  if (!selected) return selected;
  const calories = selected.calories || 0;
  if (calories > 0) return selected;
  const atwater = (selected.carbs || 0) * 4 + (selected.protein || 0) * 4 + (selected.fat || 0) * 9;
  return { ...selected, calories: atwater };
}

const foodProfiles = [
  {
    id: "addedSugar",
    pattern: /\b(dextro|glucose|druiven.?suiker|sugar|suiker|honey|honing|jam|syrup|stroop)\b/i,
    expectsCarbs: true,
    ranges: { carbs: [55, 105], fat: [0, 8], protein: [0, 8], calories: [220, 450] }
  },
  {
    id: "fat",
    pattern: /\b(oil|olie|butter|boter|mayo|mayonnaise|dressing|pesto|cream|room)\b/i,
    ranges: { carbs: [0, 20], fat: [20, 105], protein: [0, 18], calories: [180, 950] }
  },
  {
    id: "starch",
    pattern: /\b(rice|rijst|pasta|spaghetti|noodle|bami|mie|oat|havermout|potato|aardappel|bread|brood|toast|bagel|bun|tortilla|roti|ruti|chapati|paratha|khichuri|khichdi|biryani|biriyani|cereal|pizza|fries|friet|corn|mais|maize|wheat|barley|quinoa|bulgur|farro|couscous|grain|grains)\b/i,
    expectsCarbs: true,
    ranges: { carbs: [10, 85], fat: [0, 28], protein: [0, 25], calories: [55, 460] }
  },
  {
    id: "fruit",
    pattern: /\b(banana|banaan|apple|appel|orange|sinaasappel|mandarin|pear|peer|berries|berry|strawberries|aardbei|blueberries|raspberries|grapes|druiven|pineapple|ananas|melon|meloen|cantaloupe|lemon|citroen)\b/i,
    expectsCarbs: true,
    ranges: { carbs: [3, 35], fat: [0, 5], protein: [0, 6], calories: [15, 150] }
  },
  {
    id: "legume",
    pattern: /\b(bean|beans|bonen|chickpea|chickpeas|chola|kikkererwt|lentil|lentils|linzen|dal|daal|dhal|peas|erwten)\b/i,
    expectsCarbs: true,
    ranges: { carbs: [8, 45], fat: [0, 12], protein: [4, 28], calories: [70, 280] }
  },
  {
    id: "vegetable",
    pattern: /\b(salad|salade|green beans|string beans|haricots verts|sperziebonen|broccoli|cauliflower|bloemkool|brussels sprouts|spruit|asparagus|zucchini|courgette|squash|kumra|pumpkin|carrot|wortel|onion|ui|tomato|tomaat|pepper|peppers|paprika|mushroom|champignon|spinach|spinazie|kale|boerenkool|shak|saag|lettuce|sla|cucumber|komkommer|eggplant|aubergine|artichoke|artisjok|greens|vaji|bhaji|olives)\b/i,
    ranges: { carbs: [0, 25], fat: [0, 10], protein: [0, 14], calories: [5, 160] }
  },
  {
    id: "protein",
    pattern: /\b(chicken|kip|beef|rund|pork|varken|fish|vis|salmon|zalm|tuna|tonijn|shrimp|garnalen|egg|eggs|ei|bacon|spek|sausage|worst|ham|cheese|kaas|yogurt|yoghurt|tofu|tempeh|soy)\b/i,
    ranges: { carbs: [0, 22], fat: [0, 65], protein: [3, 55], calories: [35, 650] }
  },
  {
    id: "nuts",
    pattern: /\b(almond|amandel|nut|noten|peanut|pinda|walnut|cashew|pistachio)\b/i,
    ranges: { carbs: [5, 35], fat: [30, 75], protein: [8, 35], calories: [420, 750] }
  }
];

function foodProfileFor(text) {
  return foodProfiles.find(profile => profile.pattern.test(text)) || null;
}

function foodProfileIDsFor(text) {
  return foodProfiles
    .filter(profile => profile.pattern.test(text))
    .map(profile => profile.id);
}

function per100FromMatch(match) {
  const grams = match?.portionGrams || gramsFromPortion(match?.portion) || 100;
  const divisor = grams > 0 ? grams : 100;
  return {
    carbs: (match?.carbs || 0) * 100 / divisor,
    fat: (match?.fat || 0) * 100 / divisor,
    protein: (match?.protein || 0) * 100 / divisor,
    fiber: (match?.fiber || 0) * 100 / divisor,
    calories: (match?.calories || 0) * 100 / divisor
  };
}

function isOutsideFoodProfile(profile, per100) {
  return Object.entries(profile.ranges).some(([key, [min, max]]) => {
    const value = per100[key] || 0;
    const lower = Math.max(0, min - Math.max(2, min * 0.25));
    const upper = max + Math.max(5, max * 0.25);
    return value < lower || value > upper;
  });
}

function hasUnrequestedPrepMismatch(query, candidate) {
  const q = String(query || "").toLowerCase();
  const c = String(candidate || "").toLowerCase();
  const starch = foodProfiles.find(profile => profile.id === "starch").pattern.test(q);
  const queryPrep = /\b(raw|dry|dried|uncooked|ongekookt|rauw|fried|gebakken|roasted|geroosterd|cooked|gekookt)\b/i;
  if (starch && /\b(raw|dry|dried|uncooked|ongekookt|rauw|flour|meel|powder)\b/i.test(c) && !queryPrep.test(q)) return true;
  if (/\b(fried|breaded|candied|sweetened|syrup|pie filling|chips|tots|paste|pickled)\b/i.test(c) && !queryPrep.test(q)) return true;
  return false;
}

function hasCompetingFoodCategory(query, candidate) {
  const qProfiles = new Set(foodProfileIDsFor(query));
  const cProfiles = foodProfileIDsFor(candidate);
  if (!qProfiles.size || !cProfiles.length) return false;

  const toleratedPairs = new Set([
    "protein:fat",
    "vegetable:fat",
    "vegetable:protein"
  ]);
  for (const candidateProfile of cProfiles) {
    if (qProfiles.has(candidateProfile)) continue;
    const tolerated = [...qProfiles].some(queryProfile => toleratedPairs.has(`${queryProfile}:${candidateProfile}`));
    if (!tolerated) return true;
  }
  return false;
}

function hasUnrequestedFoodForm(query, candidate) {
  const q = String(query || "").toLowerCase();
  const c = String(candidate || "").toLowerCase();
  if (/\begg\b/i.test(q) && /\begg whites?\b/i.test(c) && !/\b(white|whites|eiwit)\b/i.test(q)) return true;
  const requestedForm = /\b(juice|sap|smoothie|sauce|saus|dressing|yogurt|yoghurt|mayo|mayonnaise|flour|meel|powder|poeder|spice mix|seasoning|restaurant|fried|gebakken|breaded|gepaneerd|cookie|cookies|biscuit|cracker|cereal|sweet and sour)\b/i;
  const riskyForm = /\b(juice|sap|smoothie|sauce|saus|dressing|yogurt|yoghurt|mayo|mayonnaise|flour|meel|powder|poeder|spice mix|seasoning|restaurant|cookie|cookies|biscuit|cracker|cereal|sweet and sour)\b/i;
  if (riskyForm.test(c) && !requestedForm.test(q)) return true;
  return false;
}

function isBroadFoodCategoryQuery(query, candidate) {
  const q = String(query || "").toLowerCase();
  const c = String(candidate || "").toLowerCase();
  const broadQueryPatterns = [
    /\b(nuts|noten)\b/i,
    /\b(salad|salade)\b/i,
    /\b(beans|bonen)\b/i,
    /\b(fruit|vegetables|groente|groenten)\b/i
  ];
  const hasBroadQuery = broadQueryPatterns.some(pattern => pattern.test(q));
  if (!hasBroadQuery) return false;
  const queryTokens = new Set(q.split(/[^a-z0-9]+/i).filter(token => token.length > 2));
  const candidateTokens = c.split(/[^a-z0-9]+/i).filter(token => token.length > 2);
  const novelTokenCount = candidateTokens.filter(token => !queryTokens.has(token)).length;
  return novelTokenCount >= 2;
}

function isUsableFinalMeal(final, enriched) {
  if (!final || !Array.isArray(final.items)) return false;
  if (enriched.length > 0 && final.items.length === 0) return false;
  if (final.items.length < Math.min(enriched.length, 1)) return false;
  return final.items.every(item =>
    item &&
    string(item.name, "") &&
    Number.isFinite(Number(item.carbs)) &&
    Number.isFinite(Number(item.fat)) &&
    Number.isFinite(Number(item.protein)) &&
    Number.isFinite(Number(item.calories))
  );
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
    `The user interface language is ${args.language}, but ingredient names must be concise English database lookup terms unless the user supplied a brand/product name.`,
    "Do not estimate macros. Only identify likely ingredients and portions.",
    "For compound meals, split important carb/fat/protein sources into separate ingredients.",
    "For photo-only input, infer the visible meal components and approximate portions; return at least one ingredient when food is visible.",
    "When visual portion size is uncertain, use conservative small cooked portions rather than dry/raw portions.",
    "Preserve user-provided food words, brands, raw/cooked/dry wording, and exact gram/ml quantities, including hyphenated forms such as 230-gram and phrases such as weighing 30 grams.",
    "When preparation is not specified, assume the edible form a person would normally log, not raw dry flour/powder forms.",
    "Return a JSON object with an ingredients array. Each ingredient must have name, portion, and brand."
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
    "For insulin dosing, overestimating carbohydrates is more dangerous than underestimating. If portion size is uncertain, choose the lower plausible carbohydrate estimate and keep the reason visible in item names/portions.",
    "Do not turn vague labels like vegetable, sauce, curry, dal, vaji, or salad into a large starch portion unless the text or image clearly shows a large starch serving.",
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
      temperature: 0,
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

async function callGeminiJSON({ apiKey, model, system, user, images, schema }) {
  const parts = [{ text: `${system}\n\n${user}` }];
  for (const dataUrl of images || []) {
    const parsed = parseDataURL(dataUrl);
    if (parsed) {
      parts.push({ inlineData: { mimeType: parsed.mimeType, data: parsed.base64 } });
    }
  }
  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const generationConfig = {
    temperature: 0,
    responseMimeType: "application/json"
  };
  if (schema) {
    generationConfig.responseSchema = geminiResponseSchema(schema);
  }
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts }],
      generationConfig
    })
  });
  const json = await response.json();
  if (!response.ok) {
    if (schema && /responseSchema|generationConfig|schema/i.test(json.error?.message || "")) {
      return callGeminiJSON({ apiKey, model, system, user, images });
    }
    throw new Error(json.error?.message || `Gemini HTTP ${response.status}`);
  }
  const text = json.candidates?.[0]?.content?.parts?.map(part => part.text || "").join("\n");
  return parseJSONText(text);
}

function geminiResponseSchema(schema) {
  if (!schema || typeof schema !== "object") return schema;
  const out = {};
  for (const [key, value] of Object.entries(schema)) {
    if (key === "additionalProperties") continue;
    if (key === "type" && typeof value === "string") {
      out.type = value.toUpperCase();
      continue;
    }
    if (key === "properties" && value && typeof value === "object") {
      out.properties = Object.fromEntries(Object.entries(value).map(([name, child]) => [name, geminiResponseSchema(child)]));
      out.propertyOrdering = Object.keys(value);
      continue;
    }
    if (key === "items") {
      out.items = geminiResponseSchema(value);
      continue;
    }
    out[key] = Array.isArray(value)
      ? value.map(item => geminiResponseSchema(item))
      : geminiResponseSchema(value);
  }
  return out;
}

function fallbackIntents(mealText) {
  const pieces = mealText
    .split(/\s*(?:,|\+| and | en | met | e )\s*/i)
    .map(x => x.trim())
    .filter(Boolean);
  return {
    mealName: mealText || "Meal",
    mealPortion: "",
    ingredients: pieces.length ? pieces.map(piece => {
      const match = /^(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|milliliter|milliliters)\s+(.+)$/i.exec(piece);
      if (!match) return { name: piece, portion: "", brand: "" };
      return {
        name: match[3].trim(),
        portion: `${match[1].replace(",", ".")} ${match[2].toLowerCase()}`,
        brand: ""
      };
    }) : []
  };
}

function normalizeIntents(intents, mealText) {
  const ingredients = Array.isArray(intents)
    ? intents
    : (Array.isArray(intents?.ingredients) ? intents.ingredients : []);
  if (!ingredients.length && mealText) {
    return fallbackIntents(mealText).ingredients;
  }
  const normalized = ingredients
    .map(item => ({
      name: String(item.name || item.ingredient || item.food || item.foodName || "").trim(),
      portion: String(item.portion || "").trim(),
      brand: normalizeBrand(item.brand)
    }))
    .map(item => recoverExplicitPortionFromText(item, mealText))
    .filter(item => item.name);
  const fallback = fallbackIntents(mealText).ingredients;
  if (
    fallback.length > 0 &&
    fallback.every(item => hasExplicitGramPortion(item.portion))
  ) {
    return fallback;
  }
  return normalized.length || !mealText ? normalized : fallbackIntents(mealText).ingredients;
}

function recoverExplicitPortionFromText(item, mealText) {
  if (!mealText || gramsFromPortion(item.portion) !== null) return item;
  if (isTraceSeasoningName(item.name)) return item;
  const text = String(mealText || "");
  const tokens = String(item.name || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/i)
    .filter(token => token.length >= 4 && !/^(with|without|fresh|cooked|boiled|roasted|baked|plain|raw)$/.test(token));
  if (!tokens.length) return item;

  for (const token of tokens) {
    const escaped = escapeRegExp(token);
    const before = new RegExp(`(\\d+(?:[.,]\\d+)?)\\s*[- ]?\\s*(g|gram|grams|ml|milliliter|milliliters)\\s+(?:of\\s+)?[^,.;]{0,80}\\b${escaped}\\b`, "i");
    const beforeMatch = before.exec(text);
    if (beforeMatch) {
      return { ...item, portion: `${beforeMatch[1].replace(",", ".")} ${normalizeUnit(beforeMatch[2])}` };
    }

    const after = new RegExp(`\\b${escaped}\\b[^,.;]{0,80}\\b(?:weighing|weighs|weight|of|at)\\s+(\\d+(?:[.,]\\d+)?)\\s*[- ]?\\s*(g|gram|grams|ml|milliliter|milliliters)\\b`, "i");
    const afterMatch = after.exec(text);
    if (afterMatch) {
      return { ...item, portion: `${afterMatch[1].replace(",", ".")} ${normalizeUnit(afterMatch[2])}` };
    }
  }
  return item;
}

function normalizeUnit(unit) {
  return /^m/i.test(String(unit || "")) ? "ml" : "g";
}

function normalizeBrand(brand) {
  const value = String(brand || "").trim();
  return /^(generic|unknown|n\/a|none|geen|onbekend)$/i.test(value) ? "" : value;
}

function applyUncertainImagePortionGuard(ingredients, { mealText, images }) {
  if (!Array.isArray(images) || images.length === 0) return ingredients;
  if (hasExplicitGramPortion(mealText)) return ingredients;
  return ingredients.map(item => {
    const grams = gramsFromPortion(item.portion);
    if (grams === null) return item;
    const guardedGrams = conservativeVisualGrams(item.name, grams);
    if (guardedGrams === grams) return item;
    return {
      ...item,
      portion: `${round1(guardedGrams)} g visual estimate`
    };
  });
}

function conservativeVisualGrams(name, grams) {
  const text = String(name || "").toLowerCase();
  const cap = (max, scale = 0.55) => Math.min(grams, Math.max(25, Math.round(grams * scale)), max);
  if (/(rice|rijst|pasta|spaghetti|noodle|bami|mie|khichuri|khichdi|biryani|biriyani)/i.test(text)) return cap(85, 0.5);
  if (/(bread|brood|toast|bagel|bun|roti|ruti|chapati|paratha|tortilla)/i.test(text)) return cap(70, 0.6);
  if (/(potato|aardappel|fries|friet|yam|sweet potato|zoete aardappel)/i.test(text)) return cap(90, 0.55);
  if (/(dal|daal|dhal|lentil|lentils|bean|beans|chickpea|chola|peas)/i.test(text)) return cap(80, 0.55);
  if (/(juice|sap|sauce|saus|gravy|curry)/i.test(text)) return cap(50, 0.5);
  if (/(lassi|smoothie|milkshake|soda|soft drink|drink|beverage|frisdrank)/i.test(text)) return cap(120, 0.5);
  if (/(mango|banana|banaan|apple|appel|fruit|dates|date)/i.test(text)) return cap(90, 0.65);
  return grams;
}

function hasExplicitGramPortion(portion) {
  return /(\d+(?:[.,]\d+)?)\s*(g|gram|grams|ml|milliliter|milliliters)\b/i.test(String(portion));
}

function fallbackFinalMeal(mealText, enriched) {
  const items = enriched.map(item => {
    const selected = item.selected;
    const scaled = scaleSelectedForIngredient(selected, item);
    return {
      name: item.name,
      portion: item.portion || selected?.portion || "1 serving",
      carbs: round1(scaled.carbs),
      fat: round1(scaled.fat),
      protein: round1(scaled.protein),
      fiber: round1(scaled.fiber),
      calories: round1(scaled.calories),
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

function scaleSelectedForIngredient(selected, ingredient) {
  if (!selected) {
    return { carbs: 0, fat: 0, protein: 0, fiber: 0, calories: 0 };
  }
  const portionGrams = gramsFromPortion(ingredient.portion);
  const nameGrams = gramsFromPortion(ingredient.name);
  const qualitativeGrams = qualitativeGramsFromText(`${ingredient.name} ${ingredient.portion}`);
  const ingredientGrams = portionGrams !== null ? portionGrams : (nameGrams !== null ? nameGrams : qualitativeGrams);
  const sourceGrams = selected.portionGrams || gramsFromPortion(selected.portion);
  const edibleScale = edibleFractionForLoggedWeight(ingredient);
  const scale = (ingredientGrams !== null && sourceGrams ? ingredientGrams / sourceGrams : 1) * edibleScale;
  return {
    carbs: (selected.carbs || 0) * scale,
    fat: (selected.fat || 0) * scale,
    protein: (selected.protein || 0) * scale,
    fiber: (selected.fiber || 0) * scale,
    calories: (selected.calories || 0) * scale
  };
}

function edibleFractionForLoggedWeight(ingredient) {
  const text = `${ingredient.name} ${ingredient.portion}`.toLowerCase();
  if (/\b(without|no)\s+(?:the\s+)?(?:peel|skin|shell)s?\b/i.test(text)) return 1;
  const hasShellOrPeel = /\b(?:with|in)\s+(?:the\s+|their\s+)?(?:peel|skin|shell)s?\b/i.test(text);
  if (!hasShellOrPeel) return 1;
  if (/\b(banana|banaan)\b/i.test(text)) return 0.65;
  if (/\b(orange|sinaasappel|mandarin|mango|avocado)\b/i.test(text)) return 0.72;
  if (/\b(groundnut|peanut|nut|nuts)\b/i.test(text)) return 0.55;
  if (/\b(egg|ei)\b/i.test(text)) return 0.88;
  return 0.8;
}

function qualitativeGramsFromText(text) {
  const value = String(text || "").toLowerCase();
  if (/\bminiature|mini\b/.test(value)) return 25;
  if (/\bfun size\b/.test(value)) return 18;
  if (/\b(egg|ei)\b/.test(value) && /\b(piece|one|1)\b/.test(value)) return 50;
  if (/\bsmall\b/.test(value)) {
    if (/\b(fr(i|y)es|chips|crisps)\b/.test(value)) return 70;
    if (/\b(croissant|cookie|doughnut|donut|bar|sandwich|hamburger|taco)\b/.test(value)) return 45;
    return 60;
  }
  if (/\bmedium\b/.test(value)) {
    if (/\b(soda|cola|drink|juice)\b/.test(value)) return 450;
    if (/\b(fr(i|y)es|chips|crisps)\b/.test(value)) return 110;
    if (/\b(cookie|doughnut|donut|bar|bag)\b/.test(value)) return 40;
    if (/\b(hamburger|sandwich|taco)\b/.test(value)) return 120;
    return 100;
  }
  if (/\bcup\b/.test(value)) {
    if (/\b(grapes|berries|fruit)\b/.test(value)) return 150;
    if (/\b(yogurt|yoghurt|milk|soup)\b/.test(value)) return 240;
    if (/\bice cream\b/.test(value)) return 130;
    return 200;
  }
  if (/\b(tbsp|tablespoon)\b/.test(value)) return 15;
  if (/\b(tsp|teaspoon)\b/.test(value)) return 5;
  if (/\b(packet|pack)\b/.test(value)) return 12;
  if (/\b(bottle|can)\b/.test(value) && /\b(water|cola|soda|drink)\b/.test(value)) return 355;
  return null;
}

function isTraceSeasoningName(name) {
  const text = String(name || "").toLowerCase();
  if (/\b(salt|pepper|spice|spices|seasoning|herb|herbs|sucralose|sweetener)\b/i.test(text)) return true;
  if (/\b(ginger|garlic|coffee leaves|tea leaves|coffee leaf|tea leaf|coffee beans)\b/i.test(text) && !hasExplicitGramPortion(text)) return true;
  if (/\b(boiled coffee beans|coffee beans with salt|coffee leaf drink|coffee leaves)\b/i.test(text)) return true;
  return false;
}

function heuristicEstimate(ingredient) {
  const text = `${ingredient.name} ${ingredient.portion}`.toLowerCase();
  const estimate = (name, portion, carbs, fat, protein, fiber, calories, sourceID = "localReference") => ({
    sourceID,
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
  const portionGrams = gramsFromPortion(ingredient.portion);
  const nameGrams = gramsFromPortion(ingredient.name);
  const grams = portionGrams !== null ? portionGrams : (nameGrams !== null ? nameGrams : qualitativeGramsFromText(text));
  const per100 = (name, carbs, fat, protein, fiber, calories) => {
    if (grams === null) return null;
    const scale = grams / 100;
    return estimate(
      `${name} estimate`,
      `${round1(grams)} g`,
      round1(carbs * scale),
      round1(fat * scale),
      round1(protein * scale),
      round1(fiber * scale),
      Math.round(calories * scale)
    );
  };
  if (isTraceSeasoningName(text)) {
    return estimate("Trace seasoning", ingredient.portion || "trace", 0, 0, 0, 0, 0);
  }
  const commonEstimate =
    (/\b(water|unsweetened water|bottled water|boiled water)\b/i.test(text) && estimate("Water", ingredient.portion || "water", 0, 0, 0, 0, 0)) ||
    (/(egg white|eiwit)/i.test(text) && per100("Egg whites", 0.7, 0.2, 11, 0, 52)) ||
    (/(tofu|tempeh|soy)/i.test(text) && per100("Tofu", 2, 5, 8, 1, 90)) ||
    (/(noodle soup|soup|bouillon|broth)/i.test(text) && per100("Soup", 7, 2, 3, 1, 60)) ||
    (/(spaghetti|pasta|noodle)/i.test(text) && per100("Cooked pasta", 25, 1.1, 5, 1.8, 158)) ||
    (/(roti|ruti|chapati|paratha)/i.test(text) && per100("Flatbread", 46, 7, 8, 4, 300)) ||
    (/(puffed[-\s]?rice)/i.test(text) && per100("Puffed rice", 83, 1, 7, 1, 383)) ||
    (/(khichuri|khichdi)/i.test(text) && per100("Rice and lentil dish", 22, 4, 5, 3, 145)) ||
    (/(biryani|biriyani)/i.test(text) && per100("Biryani rice dish", 27, 8, 8, 2, 210)) ||
    (/(wheat berr|barley|quinoa|bulgur|farro|couscous|grain|grains)/i.test(text) && per100("Cooked grains", 24, 0.7, 4, 3, 120)) ||
    (/(caesar salad|green salad|mixed salad|salad|salade)/i.test(text) && per100("Salad", 4, 4, 2, 1.5, 65)) ||
    (/(green beans|string beans|haricots verts|sperziebonen)/i.test(text) && per100("Green beans", 7, 0.2, 1.8, 3.4, 31)) ||
    (/(cookie|cookies|biscuit|biscuits|cake|muffin|pastry|brownie|donut|doughnut|koek|koekje|gebak)/i.test(text) && per100("Baked sweet snack", 62, 18, 6, 2, 430)) ||
    (/(oatmeal|havermout)/i.test(text) && per100("Oatmeal", 12, 1.4, 2.5, 1.7, 68)) ||
    (/(tortilla)/i.test(text) && per100("Tortilla", 45, 8, 8, 3, 290)) ||
    (/(potato chips|chips)/i.test(text) && per100("Potato chips", 53, 35, 6, 4.8, 536)) ||
    (/\b(chickpea|chickpeas|chola|kikkererwt)\b/i.test(text) && per100("Chickpeas", 27.4, 2.6, 8.9, 7.6, 164)) ||
    (/(dal|daal|dhal|lentil|lentils|linzen)/i.test(text) && per100("Lentil dal", 14, 2, 7, 4, 110)) ||
    (/(artichoke|artisjok)/i.test(text) && per100("Artichokes", 10.5, 0.2, 3.3, 5.4, 47)) ||
    (/(lemon|citroen)/i.test(text) && per100("Lemon", 9.3, 0.3, 1.1, 2.8, 29)) ||
    (/(kale|boerenkool|spinach|spinazie)/i.test(text) && per100("Leafy greens", 4.4, 0.4, 2.9, 2.6, 23)) ||
    (/(crouton)/i.test(text) && per100("Croutons", 65, 10, 12, 5, 407)) ||
    (/(caesar dressing|dressing)/i.test(text) && per100("Caesar dressing", 6, 54, 2, 0, 540)) ||
    (/(achar|pickle|chutney|relish)/i.test(text) && per100("Pickled condiment", 18, 4, 2, 3, 110)) ||
    (/(parmesan)/i.test(text) && per100("Parmesan", 4.1, 29, 38, 0, 431)) ||
    (/(eggplant|aubergine)/i.test(text) && per100("Eggplant", 6, 0.2, 1, 3, 25)) ||
    (/(pesto)/i.test(text) && per100("Pesto", 6, 48, 5, 1, 460)) ||
    (/(chicken salad)/i.test(text) && per100("Chicken salad", 5, 18, 17, 1, 250)) ||
    (/(yam|sweet potato|zoete aardappel)/i.test(text) && per100("Sweet potato", 20, 0.1, 1.6, 3, 86)) ||
    (/(roasted potato|baked potato|\bpotato\b|potatoes|aardappel)/i.test(text) && per100("Potato", 17, 0.1, 2, 2.2, 77)) ||
    (/(cooked rice|white rice|witte rijst)/i.test(text) && per100("White rice", 28, 0.3, 2.7, 0.4, 130)) ||
    (/(bread|brood|toast|bagel|bun)/i.test(text) && per100("Bread", 49, 3.2, 9, 2.7, 265)) ||
    (/(chicken apple sausage|sausage|worst)/i.test(text) && per100("Sausage", 4, 13, 14, 0, 190)) ||
    (/(cheetos|corn chips|potato sticks|chips|crisps)/i.test(text) && per100("Snack chips", 55, 32, 6, 4, 530)) ||
    (/(skittles|hard candy|candy|caramel|fruit leather|jelly|jam)/i.test(text) && per100("Candy", 82, 4, 2, 1, 380)) ||
    (/(cola|soda|soft drink|pepper soda|juice drink)/i.test(text) && per100("Sweetened drink", 10.5, 0, 0, 0, 42)) ||
    (/(pizza roll)/i.test(text) && per100("Pizza snack", 30, 10, 10, 2, 250)) ||
    (/(banana|banaan)/i.test(text) && per100("Banana", 22.8, 0.3, 1.1, 2.6, 89)) ||
    (/(apple|appel)/i.test(text) && per100("Apple", 13.8, 0.2, 0.3, 2.4, 52)) ||
    (/(orange|mandarin)/i.test(text) && per100("Orange", 12, 0.1, 0.9, 2.4, 47)) ||
    (/\b(date|dates)\b/i.test(text) && per100("Dates", 75, 0.2, 2.5, 8, 282)) ||
    (/(pear|peer)/i.test(text) && per100("Pear", 15, 0.1, 0.4, 3.1, 57)) ||
    (/(berries|strawberries|aardbei)/i.test(text) && per100("Berries", 12, 0.3, 0.8, 2, 50)) ||
    (/(cantaloupe|meloen)/i.test(text) && per100("Cantaloupe", 8.2, 0.2, 0.8, 0.9, 34)) ||
    (/(shak|saag|vaji|bhaji|bell pepper|peppers|tomato|mushroom|asparagus|zucchini|squash|kumra|pumpkin|carrot|onion|mixed greens|olives)/i.test(text) && per100("Vegetables", 6, 3, 2, 2.5, 60)) ||
    (/(cauliflower|bloemkool)/i.test(text) && per100("Cauliflower", 5, 0.3, 1.9, 2, 25)) ||
    (/(broccoli|brussels sprouts|spruit)/i.test(text) && per100("Broccoli", 7, 0.4, 2.8, 2.6, 34)) ||
    (/(corn|mais)/i.test(text) && per100("Corn", 21, 1.5, 3.4, 2.4, 96)) ||
    (/(cucumber|komkommer)/i.test(text) && per100("Cucumber", 3.6, 0.1, 0.7, 0.5, 15)) ||
    (/(shrimp|garnalen)/i.test(text) && per100("Shrimp", 0.2, 0.3, 24, 0, 99)) ||
    (/(tuna|tonijn)/i.test(text) && per100("Tuna", 0, 1, 29, 0, 130)) ||
    (/\b(fish|vis)\b/i.test(text) && per100("Fish", 0, 5, 22, 0, 140)) ||
    (/(chicken apple sausage|sausage|worst)/i.test(text) && per100("Sausage", 4, 13, 14, 0, 190)) ||
    (/(scrambled eggs|egg|ei)/i.test(text) && per100("Eggs", 1.6, 11, 10, 0, 149)) ||
    (/(bacon|spek)/i.test(text) && per100("Bacon", 1.4, 42, 37, 0, 541)) ||
    (/(pizza)/i.test(text) && per100("Pizza", 33, 10, 12, 2.3, 266)) ||
    (/(cheese|kaas)/i.test(text) && per100("Cheese", 1.3, 33, 25, 0, 402)) ||
    (/(olive oil|olijfolie)/i.test(text) && per100("Olive oil", 0, 100, 0, 0, 884)) ||
    (/(bean|beans|bonen)/i.test(text) && per100("Beans", 18, 0.5, 7.5, 6.5, 115)) ||
    (/(chicken|kip)/i.test(text) && per100("Chicken", 0, 3.6, 31, 0, 165)) ||
    (/(grapes|pineapple|ananas)/i.test(text) && per100("Fruit", 18, 0.2, 0.7, 1.2, 70)) ||
    (/(almonds|amandel)/i.test(text) && per100("Almonds", 22, 50, 21, 12.5, 579)) ||
    (/(nuts|noten)/i.test(text) && per100("Mixed nuts", 21, 54, 20, 8, 600));
  if (commonEstimate) return commonEstimate;
  if (/(spaghetti|pasta|noodle)/i.test(text)) {
    return estimate("Cooked pasta estimate", ingredient.portion || "250 g cooked", 75, 2, 13, 4, 395);
  }
  if (/(rice|rijst|risotto)/i.test(text)) {
    return estimate("Cooked rice estimate", ingredient.portion || "150 g cooked", 40, 0.8, 4, 1, 195);
  }
  if (/(pizza)/i.test(text)) {
    return estimate("Pizza estimate", ingredient.portion || "1 pizza", 90, 30, 35, 4, 800);
  }
  if (/(banana|banaan)/i.test(text)) {
    return estimate("Banana estimate", ingredient.portion || "1 medium banana (118 g)", 27, 0.4, 1.3, 3.1, 105);
  }
  if (/\b(date|dates)\b/i.test(text)) {
    const count = /(\d+(?:[.,]\d+)?)\s*(?:piece|pieces|date|dates)\b/i.exec(text);
    const dateCount = count ? Number(count[1].replace(",", ".")) : 1;
    return estimate("Dates estimate", ingredient.portion || `${dateCount} date`, round1(dateCount * 6), 0, round1(dateCount * 0.2), round1(dateCount * 0.7), Math.round(dateCount * 23));
  }
  if (/\b(juice|sap)\b/i.test(text)) {
    return estimate("Juice estimate", ingredient.portion || "50 g visual estimate", 5, 0, 0, 0, 22);
  }
  if (/(dextro|glucose|druiven.?suiker|hypo).*(tablet|tab|pastille)|(?:tablet|tab|pastille).*(dextro|glucose|druiven.?suiker)/i.test(text)) {
    const count = tabletCount(text) || 3;
    return estimate(
      "Glucose tablet estimate",
      `${count} tablets`,
      round1(count * 5.3),
      0,
      0,
      0,
      Math.round(count * 21.7)
    );
  }
  if (/(bread|brood|toast|bagel|bun)/i.test(text)) {
    return estimate("Bread estimate", ingredient.portion || "1 serving", 22, 2, 5, 2, 125);
  }
  if (/(potato|aardappel|fries|friet)/i.test(text)) {
    return estimate("Potato estimate", ingredient.portion || "100 g", 20, 0.1, 2, 2, 90);
  }
  if (/(roti|ruti|chapati|paratha)/i.test(text)) {
    return estimate("Flatbread estimate", ingredient.portion || "1 piece", 22, 3.5, 4, 2, 145);
  }
  if (/(dal|daal|dhal|lentil|lentils|linzen)/i.test(text)) {
    return estimate("Lentil dal estimate", ingredient.portion || "1 small serving", 12, 2, 6, 4, 100);
  }
  if (/\b(chola|chickpea|chickpeas|kikkererwt)\b/i.test(text)) {
    return estimate("Chickpeas estimate", ingredient.portion || "2 tablespoons", 8, 1, 3, 2, 55);
  }
  if (/(vaji|bhaji|shak|saag|vegetable|groente)/i.test(text)) {
    return estimate("Vegetable side estimate", ingredient.portion || "1 small serving", 6, 4, 2, 2.5, 75);
  }
  return null;
}

function tabletCount(text) {
  const match = /(\d+(?:[.,]\d+)?)\s*(?:x\s*)?(?:tablet|tablets|tab|tabs|pastille|pastilles)\b/i.exec(text);
  return match ? Number(match[1].replace(",", ".")) : null;
}

async function searchOpenFoodFacts(query) {
  const url = new URL("https://world.openfoodfacts.org/api/v2/search");
  url.searchParams.set("search_terms", query);
  url.searchParams.set("fields", "code,product_name,brands,nutriments,serving_size,serving_quantity,nutrition_data_completeness,image_url,url");
  url.searchParams.set("page_size", "6");
  url.searchParams.set("json", "1");
  let lastStatus = 0;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await fetch(url, {
      headers: {
        "accept": "application/json",
        "user-agent": "Trio-FoodFinder-AgentLab/0.1"
      }
    });
    if (response.ok) {
      const json = await response.json();
      return (json.products || []).map(product => offResult(product, query)).filter(Boolean);
    }
    lastStatus = response.status;
    if (![429, 500, 502, 503, 504].includes(response.status)) break;
    await delay(250 * (attempt + 1));
  }
  throw new Error(`OpenFoodFacts HTTP ${lastStatus}`);
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

function offResult(product, fallbackName) {
  const nutriments = product.nutriments || {};
  const name = string(product.product_name, fallbackName);
  if (!name || !Object.keys(nutriments).length) return null;
  const code = string(product.code, "");
  const serving = string(product.serving_size, "100 g");
  const portionGrams = gramsFromPortion(serving) || number(product.serving_quantity, null) || 100;
  const completeness = clamp(number(product.nutrition_data_completeness, 0.35), 0.35, 1);
  return {
    sourceID: "openFoodFacts",
    name,
    brand: string(product.brands, ""),
    portion: serving,
    portionGrams,
    carbs: offNutrientForPortion(nutriments, "carbohydrates", portionGrams),
    fat: offNutrientForPortion(nutriments, "fat", portionGrams),
    protein: offNutrientForPortion(nutriments, "proteins", portionGrams),
    fiber: offNutrientForPortion(nutriments, "fiber", portionGrams),
    calories: offNutrientForPortion(nutriments, "energy-kcal", portionGrams),
    sourceURL: string(product.url, code ? `https://world.openfoodfacts.org/product/${code}` : ""),
    verifiedScore: completeness,
    sourceVerified: completeness >= 0.6,
    imageURL: string(product.image_url, "")
  };
}

function offNutrientForPortion(nutriments, key, portionGrams) {
  const serving = number(nutriments[`${key}_serving`], null);
  if (serving !== null && Number.isFinite(serving)) return serving;
  const per100 = number(nutriments[`${key}_100g`], null);
  if (per100 !== null && Number.isFinite(per100)) return per100 * (portionGrams || 100) / 100;
  return 0;
}

async function searchUSDA(query, apiKey) {
  const dataTypeAttempts = ["Foundation", "SR Legacy", "Foundation,SR Legacy,Survey (FNDDS)", ""];
  let lastError;
  for (const dataType of dataTypeAttempts) {
    const url = new URL("https://api.nal.usda.gov/fdc/v1/foods/search");
    url.searchParams.set("query", query);
    url.searchParams.set("pageSize", "12");
    if (dataType) url.searchParams.set("dataType", dataType);
    url.searchParams.set("api_key", apiKey);
    const response = await fetch(url, { headers: { "accept": "application/json" } });
    if (!response.ok) {
      lastError = new Error(`USDA HTTP ${response.status}`);
      continue;
    }
    const json = await response.json();
    const results = (json.foods || []).map(usdaResult).filter(Boolean);
    if (results.length) return results;
  }
  if (lastError) throw lastError;
  return [];
}

async function searchNutritionixRestaurant(query, restaurantName, appId, apiKey) {
  const headers = {
    "accept": "application/json",
    "x-app-id": appId,
    "x-app-key": apiKey
  };
  const search = new URL("https://trackapi.nutritionix.com/v2/search/instant");
  search.searchParams.set("query", `${restaurantName} ${query}`);
  search.searchParams.set("branded", "true");
  search.searchParams.set("common", "false");
  const response = await fetch(search, { headers });
  if (!response.ok) throw new Error(`Nutritionix instant HTTP ${response.status}`);
  const json = await response.json();
  const restaurant = restaurantName.toLowerCase();
  const branded = (json.branded || [])
    .filter(item => !restaurant || String(item.brand_name || "").toLowerCase().includes(restaurant))
    .slice(0, 4);
  const details = await Promise.all(branded.map(async item => {
    if (!item.nix_item_id) return nutritionixResult(item, restaurantName);
    const detail = new URL("https://trackapi.nutritionix.com/v2/search/item");
    detail.searchParams.set("nix_item_id", item.nix_item_id);
    const detailResponse = await fetch(detail, { headers });
    if (!detailResponse.ok) return nutritionixResult(item, restaurantName);
    const detailJSON = await detailResponse.json();
    return nutritionixResult(detailJSON.foods?.[0] || item, restaurantName);
  }));
  return details.filter(Boolean);
}

function nutritionixResult(food, restaurantName) {
  const servingWeight = number(food.serving_weight_grams, null);
  const qty = number(food.serving_qty, 1);
  const unit = string(food.serving_unit, "serving");
  const portion = servingWeight ? `${round1(servingWeight)} g` : `${qty} ${unit}`;
  const name = string(food.food_name, "");
  if (!name) return null;
  return {
    sourceID: "restaurantMenu",
    name,
    brand: string(food.brand_name, restaurantName),
    dataType: "Nutritionix branded restaurant menu",
    portion,
    portionGrams: servingWeight || null,
    carbs: number(food.nf_total_carbohydrate, 0),
    fat: number(food.nf_total_fat, 0),
    protein: number(food.nf_protein, 0),
    fiber: number(food.nf_dietary_fiber, 0),
    calories: number(food.nf_calories, 0),
    sourceURL: food.nix_item_id
      ? `https://www.nutritionix.com/i/${encodeURIComponent(string(food.brand_name, restaurantName))}/${encodeURIComponent(name)}/${encodeURIComponent(food.nix_item_id)}`
      : `https://www.nutritionix.com/search?q=${encodeURIComponent(`${restaurantName} ${name}`)}`,
    verifiedScore: 0.92,
    sourceVerified: true,
    sourcePath: `location/restaurant context -> ${restaurantName} -> Nutritionix branded menu`,
    locationDerived: true,
    imageURL: string(food.photo?.thumb, "")
  };
}

function usdaResult(food) {
  const nutrients = food.foodNutrients || [];
  const dataType = string(food.dataType, "");
  const score = /foundation/i.test(dataType) ? 0.95 : (/sr legacy/i.test(dataType) ? 0.9 : 0.82);
  return {
    sourceID: "usda",
    name: string(food.description, ""),
    brand: string(food.brandOwner, ""),
    dataType,
    portion: "100 g",
    portionGrams: 100,
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
      matchScore: round2(match.verifiedScore * nameMatchScore(ingredient.name, match.name) * preparationMatchMultiplier(ingredient.name, match.name))
    }))
    .filter(match => match.matchScore >= 0.3)
    .sort((a, b) => b.matchScore - a.matchScore || sourceRank(a.sourceID) - sourceRank(b.sourceID))[0] || null;
}

function preparationMatchMultiplier(query, candidate) {
  const q = String(query || "").toLowerCase();
  const c = String(candidate || "").toLowerCase();
  let multiplier = 1;
  if (hasUnrequestedPrepMismatch(q, c)) multiplier *= 0.35;
  const preparedWords = ["fried", "candied", "chips", "tots", "bread", "pie", "paste", "pickled", "school"];
  for (const word of preparedWords) {
    if (c.includes(word) && !q.includes(word)) multiplier *= 0.55;
  }
  if (/\b(raw|nfs|as ingredient|cooked)\b/i.test(c) && !/(fried|candied|chips|tots|bread|pie|paste|pickled)/i.test(c)) {
    multiplier *= 1.08;
  }
  return multiplier;
}

function sourceRank(sourceID) {
  if (sourceID === "restaurantMenu") return 0;
  if (sourceID === "openFoodFacts") return 1;
  if (sourceID === "usda") return 2;
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
      if (lowered.includes("energy")) {
        const unit = string(nutrient.unitName, "").toLowerCase();
        if (unit && unit !== "kcal") continue;
      }
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
  const text = String(portion);
  const match = /(\d+(?:[.,]\d+)?)\s*[- ]?\s*(g|gram|grams|ml|milliliter|milliliters)\b/i.exec(text);
  if (match) return Number(match[1].replace(",", "."));
  const fluidOunce = /(\d+(?:[.,]\d+)?)\s*[- ]?\s*(?:fl\s*oz|fluid\s+ounce|fluid\s+ounces)\b/i.exec(text);
  if (fluidOunce) return Number(fluidOunce[1].replace(",", ".")) * 29.5735;
  const ounce = /(\d+(?:[.,]\d+)?)\s*[- ]?\s*(?:oz|ounce|ounces)\b/i.exec(text);
  return ounce ? Number(ounce[1].replace(",", ".")) * 28.3495 : null;
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

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function round1(value) {
  return Math.round((Number(value) || 0) * 10) / 10;
}

function round2(value) {
  return Math.round((Number(value) || 0) * 100) / 100;
}
