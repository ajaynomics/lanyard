import assert from 'node:assert/strict';
import test from 'node:test';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { productionModels } from '../runtime.mjs';
import { BORROWED_CHATGPT_PROVIDER } from '../chatgpt-lending.mjs';

const VAULT = { file: '/x/c.json', vaultKey: 'a'.repeat(64), environment: 'test' };
const SECRET = 's'.repeat(40);
const NEW = ['gpt-6.2-sol', 'gpt-6.2-astra'];

// Upstream pi added GPT-6.2 in e56d35ce5, not yet released; gpt-62.mjs stands
// in until it is. This fails on the pi-ai bump that brings them, so the stand-in
// is deleted then rather than left to drift from pi's own catalogue (#273).
test('pi-ai does not know GPT-6.2 yet; when it does, delete gpt-62.mjs and this test (#273)', () => {
  for (const provider of [openaiCodexProvider(), openaiProvider()]) {
    const known = provider.getModels().map(model => model.id).filter(id => NEW.includes(id));
    assert.deepEqual(known, [], `pi-ai now ships ${known.join(', ')} on ${provider.id}: delete agent/gpt-62.mjs and its uses (#273)`);
  }
});

const routeModels = (config, provider) => {
  const { models } = productionModels(config);
  return Object.fromEntries(NEW.map(id => [id, models.getModel(provider, id)]));
};

test('the ChatGPT subscription offers GPT-6.2 Sol and Astra, priced and tuned as upstream pi has them', () => {
  const { 'gpt-6.2-sol': sol, 'gpt-6.2-astra': astra } = routeModels({ chatgptSubscription: VAULT }, 'openai-codex');
  const sol61 = openaiCodexProvider().getModels().find(model => model.id === 'gpt-6.1-sol');
  assert.equal(sol.name, 'GPT-6.2 Sol');
  assert.equal(sol.contextWindow, 500000, "Codex's own model list");
  assert.deepEqual(sol.cost, { input: 2, output: 10, cacheRead: 0.1, cacheWrite: 2.5, tiers: [{ inputTokensAbove: 272000, input: 4, output: 15, cacheRead: 0.2, cacheWrite: 5 }] });
  assert.equal(astra.name, 'GPT-6.2 Astra');
  assert.equal(astra.contextWindow, 272000);
  assert.deepEqual(astra.cost, { input: 8, output: 40, cacheRead: 0.4, cacheWrite: 10, tiers: [{ inputTokensAbove: 272000, input: 16, output: 60, cacheRead: 0.8, cacheWrite: 20 }] });
  for (const model of [sol, astra]) {
    assert.equal(model.provider, 'openai-codex');
    assert.equal(model.api, 'openai-codex-responses');
    assert.equal(model.thinkingLevelMap.off, null, 'GPT-6.2 refuses effort "none", so no off');
    assert.deepEqual(model.thinkingLevelMap, sol61.thinkingLevelMap);
    assert.deepEqual(model.compat, sol61.compat);
  }
});

test('a borrowed ChatGPT sign-in offers them too, as its own provider; an API key gets none', () => {
  const borrowed = routeModels({ chatgptBorrow: { socketPath: '/x/lend.sock', secret: SECRET } }, BORROWED_CHATGPT_PROVIDER);
  for (const id of NEW) {
    assert.equal(borrowed[id].provider, BORROWED_CHATGPT_PROVIDER, id);
    assert.equal(borrowed[id].api, 'openai-responses', id);
    assert.equal(borrowed[id].contextWindow, 272000, id);
    assert.equal(borrowed[id].thinkingLevelMap.off, null, id);
  }
  assert.deepEqual(borrowed['gpt-6.2-astra'].cost.input, 8);
  const keyed = routeModels({ openaiApiKey: 'synthetic-key' }, 'openai');
  assert.deepEqual(Object.values(keyed), [undefined, undefined], 'the API key route waits for a key to confirm them');
});
