import assert from 'node:assert/strict';
import test from 'node:test';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';
import { productionModels } from '../runtime.mjs';
import { BORROWED_CHATGPT_PROVIDER } from '../chatgpt-lending.mjs';

const VAULT = { file: '/x/c.json', vaultKey: 'a'.repeat(64), environment: 'test' };
const SECRET = 's'.repeat(40);
const NEW = ['gpt-6.2-sol', 'gpt-6.2-astra'];

// pi-ai ships GPT-6.2 Sol and Astra since 1.6.0, which replaced agent/gpt-62.mjs
// (#273). These check each route still offers them, priced and tuned as pi has them.
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

test('a borrowed ChatGPT sign-in offers them too, as its own provider, and so does an API key, as pi-ai does', () => {
  const borrowed = routeModels({ chatgptBorrow: { socketPath: '/x/lend.sock', secret: SECRET } }, BORROWED_CHATGPT_PROVIDER);
  for (const id of NEW) {
    assert.equal(borrowed[id].provider, BORROWED_CHATGPT_PROVIDER, id);
    assert.equal(borrowed[id].api, 'openai-responses', id);
    assert.equal(borrowed[id].contextWindow, 272000, id);
    assert.equal(borrowed[id].thinkingLevelMap.off, null, id);
  }
  assert.deepEqual(borrowed['gpt-6.2-astra'].cost.input, 8);
  // pi-ai 1.6.0 lists them for the API too; the stand-in never added them there.
  const keyed = routeModels({ openaiApiKey: 'synthetic-key' }, 'openai');
  for (const id of NEW) {
    assert.equal(keyed[id].provider, 'openai', id);
    assert.equal(keyed[id].api, 'openai-responses', id);
  }
});
