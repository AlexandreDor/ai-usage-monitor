# Pricing verification — 2026-11-18

Every entry in `local/pricing.json` was checked before opening the weekly-value
fix PR. The nine paid OpenAI reference rate sets match the current official
[Standard pricing table](https://developers.openai.com/api/docs/pricing).
Existing historical periods are preserved; today's table does not establish
past effective dates. No current numeric rate needed correction beyond adding
the previously missing GPT-6.2 entries.

## Current paid API reference rates

USD per million tokens, Standard short context, with 30-minute cache writes.
Each model page was also checked directly.

| Model | Input | Cache read | Cache write | Output | Official model page |
| --- | ---: | ---: | ---: | ---: | --- |
| `gpt-5.6-sol` | 4.00 | 0.40 | 5.00 | 20.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-5.6-sol) |
| `gpt-5.6-terra` | 2.00 | 0.20 | 2.50 | 12.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-5.6-terra) |
| `gpt-5.6-luna` | 0.20 | 0.02 | 0.25 | 1.20 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-5.6-luna) |
| `gpt-6-astra` | 10.00 | 1.00 | 12.50 | 50.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6-astra) |
| `gpt-6.2-astra` | 8.00 | 0.40 | 10.00 | 40.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6.2-astra) |
| `gpt-6-sol` | 2.00 | 0.20 | 2.50 | 10.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6-sol) |
| `gpt-6.1-sol` | 2.00 | 0.10 | 2.50 | 10.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6.1-sol) |
| `gpt-6.2-sol` | 2.00 | 0.10 | 2.50 | 10.00 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6.2-sol) |
| `gpt-6-luna` | 0.10 | 0.01 | 0.125 | 0.50 | [OpenAI](https://developers.openai.com/api/docs/models/gpt-6-luna) |

GPT-5.6 Sol's model page currently describes the input/output rates as
promotional through November 30, 2026. No unannounced future rate is scheduled.
Long-context multipliers, 12-hour cache writes, Batch/Flex/Fast/Ultrafast tiers,
regional premiums, tools, and storage remain outside this reference catalog
because collected events do not identify all required billing dimensions.

## Zero-rate entries

| Provider/model | Verification and retained policy |
| --- | --- |
| `ollama/gemma4:26b-a4b-it-q8_0` | Local execution: no remote API charge. [Ollama pricing](https://ollama.com/pricing) distinguishes local execution from paid cloud tokens. Hardware/electricity are excluded. |
| `ollama/ornith:35b-q8_0` | Same local-only policy. This is not a claim about an Ollama Cloud price or model availability. |
| `openai/unknown` | Placeholder, not an API model. Zero remains the existing reporting fallback; no official price can be verified for an unidentified model. |
| `opencode/nemotron-3-ultra-free` | The [provider-maintained registry](https://github.com/anomalyco/models.dev/blob/dev/providers/opencode/models/nemotron-3-ultra-free.toml) marks this endpoint deprecated and records zero input, cached-read, and output costs. Keep those rates for historical events; unsupported cache writes are represented by zero. Verified content blob: `13eb0e882c38a8f38b4b598ab87b098cba3e2f69`. |

Zero or unknown pricing remains ineligible for weekly quota-value estimates,
even when ordinary token reports retain the configured zero cost.

## Identifiers and compatibility assumptions

The `openai-codex/` and `auto/` identifiers already configured in the catalog
reuse the corresponding model's reference rate periods. They are routing
identifiers, not separately published billing schedules.

The existing `gpt-5.6-sol-pro`, `gpt-5.6-terra-pro`, and `gpt-5.6-luna-pro`
aliases retain their local base-model mappings. The official model pages do not
list these names or a separate tariff for them, and exact-name searches in the
official documentation found no results. These are compatibility assumptions,
not independently verified Pro-model prices; this PR does not invent rates or
reinterpret historical records for those aliases.
