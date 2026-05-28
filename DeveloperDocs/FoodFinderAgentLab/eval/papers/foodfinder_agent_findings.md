# FoodFinder Agent Findings

Date: 2026-05-28

## Sources Reviewed

- SSRN 6577780 / DOI 10.2139/ssrn.6577780: Reproducibility and accuracy of LLM vision APIs for carbohydrate estimation from food photographs.
- PubMed 41314475 / DOI 10.1016/j.diabres.2025.113031: ChatGPT, Gemini, and Claude carbohydrate counting benchmark in type 1 diabetes.
- arXiv 2501.07931: Advice for Diabetes Self-Management by ChatGPT Models.
- PubMed 39250109 / PMCID PMC11770168: GPT-4 versus endocrinologists on uncertain diabetes medication decisions.
- arXiv 2508.04755: Are Large Language Models Dynamic Treatment Planners?
- SSRN 6619638: ICRM2025 guidance on generative AI for research in medicine. The SSRN page was not directly retrievable from this environment, so only bibliographic/search metadata could be confirmed.

## Practical Takeaways For Trio

1. Positive carbohydrate error matters more than symmetric MAE.
   The carbohydrate-counting studies report large overestimation events and insulin-dose uncertainty, not only average error. For Trio, a 20 g carb overestimate is a potential 2 U overdose at I:C 1:10, so FoodFinder should optimize for low max-positive error first, then reduce underestimation.

2. Vision portion estimates are stochastic even at low temperature.
   SSRN 6577780 found material within-image variability across repeated calls. The app should not trust a single vision estimate as a dosing-ready value. Use repeated low-temperature calls only where the user enables it, expose the range, and bias toward the lower plausible estimate when the range is wide.

3. Grounded ingredient lookup should be the default path.
   FoodFinder should parse intent/ingredients with the model, then verify macros through OpenFoodFacts, USDA, and later NEVO or local user datasets. The UI should keep source badges so users can tell database-backed values from AI estimates.

4. Prompting helps, but cannot be the only guardrail.
   The papers show prompt wording can change clinical choices, chain-of-thought can increase aggressiveness in insulin tasks, and LLMs may omit clarifying questions. Trio should use structured output, explicit no-insulin-advice constraints in FoodFinder, deterministic post-processing, and user confirmation before bolus use.

5. Context must be local and time-aware.
   Therapy suggestions need recent treatment context and prior accepted changes. FoodFinder needs locale/source preferences. Both should avoid repeatedly recommending the same direction without knowing what was just applied.

## Benchmark Metrics To Keep

- Carb MAE, median AE, p90 AE.
- Signed carb error distribution.
- Positive MAE and max positive error.
- Negative MAE and max negative error.
- Insulin dosing uncertainty at I:C 1:10.
- Grounded item rate.
- Candidate range when dose-guard ensemble is enabled.
- Worst cases grouped by modality and cuisine/region.

## Dataset Coverage Notes

- Nutrition5k is the best regression sanity set for controlled macro truth because it includes multi-view imagery, ingredient masses, and dish-level macros. Its weakness is cuisine bias: Google cafeteria foods in California.
- FoodBD is better for mixed dishes, sauces, visible ingredient overlap, and non-Western plates. Its nutritional labels are expert-estimated rather than lab-weighed, so use it as a robustness set rather than the only ground truth.
- NutriBench is useful for text-only, regional meal descriptions and explicit portions. It is deliberately harder for locale and preparation-style priors.
- FoodSeg103/UniFood-style datasets are strong candidates for future ingredient detection or source-grounding tests, but need a mapping layer to nutrition databases before they can directly score macro accuracy.

## Current Trio Implementation Decision

FoodFinder now has a configurable dose-guard ensemble:

- Default enabled.
- 1 to 3 safety passes.
- Temperature 0.
- For ambiguous or image-based analysis, collect candidate estimates and select the lower-quartile candidate.
- Store lower/upper carb range, candidate count, and I:C 1:10 uncertainty on `FoodAnalysisResult`.
- Show the dose-guard range in the macro summary.

This is intentionally conservative. It reduces overdose risk from positive carb errors, while leaving the user able to edit totals before opening the bolus calculator.

## Follow-up Work

- Add CI-friendly benchmark runner that can replay Nutrition5k, FoodBD, and NutriBench subsets without exposing API keys.
- Add a user-imported regional dataset format for future local food tables.
- Add NEVO as a local source for Dutch users.
- Consider provider-specific default recommendations: Claude for vision portioning when available, Gemini/OpenAI acceptable when grounded lookup dominates.
