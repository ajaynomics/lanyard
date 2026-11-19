// GPT-6.2 Sol and GPT-6.2 Astra, until pi-ai ships them (#272, #273). Upstream
// pi added both in e56d35ce5, not yet in a release; this copies that commit's
// facts onto the pinned pi-ai's own entries for the models they replace, so
// each keeps its route's API, thinking levels and tool flags.
//
// Delete this file and its two uses at the pi-ai bump that brings them:
// test/gpt-62.test.mjs fails on that bump to say so.
//
// GPT-6.2 Sol's window is its route's, as GPT-6.1 Sol's is: 500k on Codex, as
// ChatGPT's own model list gives it (upstream's 272k there is a placeholder
// until that list was read), and 272k through the Responses API. Prices are
// OpenAI's, with the same long-context tier above 272k as the others.
const REPLACES = {
  'gpt-6.2-sol': { from: 'gpt-6.1-sol', name: 'GPT-6.2 Sol', cost: { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5 } },
  'gpt-6.2-astra': { from: 'gpt-6-astra', name: 'GPT-6.2 Astra', cost: { input: 8, output: 40, cacheRead: 0.4, cacheWrite: 10 } }
};

// OpenAI's long-context price, as pi-ai's withOpenAiLongContextPricing has it.
const withLongContext = cost => ({ ...cost, tiers: [{ inputTokensAbove: 272000, input: cost.input * 2, output: cost.output * 1.5,
  cacheRead: cost.cacheRead * 2, cacheWrite: cost.cacheWrite * 2 }] });

// A provider's models with GPT-6.2 added beside what they replace; unchanged
// where pi-ai already has them or lacks the model to copy.
export function withGpt62(models) {
  const added = Object.entries(REPLACES).flatMap(([id, { from, name, cost }]) => {
    const template = models.find(model => model.id === from);
    if (!template || models.some(model => model.id === id)) return [];
    return [{ ...template, id, name, cost: withLongContext(cost) }];
  });
  return [...added, ...models];
}
