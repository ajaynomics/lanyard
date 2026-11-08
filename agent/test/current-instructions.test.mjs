import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { collapseSystemMessages, getCurrentSystemPrompt } from '@earendil-works/pi-ai/utils/transcript';
import { getSystemMessageText } from '@earendil-works/pi-ai/utils/text';
import { createRuntime } from '../runtime.mjs';
import { currentInstructions, changesIdentity } from '../current-instructions.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const avery = 'Your name is Durable Assistants. Neither can be changed.', casey = 'Your name is Casey Reyes. Neither can be changed.';

// An old thread given a new agent ("New agent from here"): the model must read
// the new name as its prompt, not as an update under the old one. An edit
// that keeps the name is an update, which keeps the prompt cache.
test('a new identity leads the next request in place of the old; an edit under the same one is appended', async t => {
  const seen = [];
  const answer = text => context => { seen.at(-1).messages = context.messages; return message(text); };
  const { faux, model } = scriptedProvider([answer('one'), answer('two'), answer('three')]);
  const watched = { ...faux.provider,
    stream: (chosen, context, options) => { seen.push({ compat: chosen.compat }); return faux.provider.stream(chosen, context, options); },
    streamSimple: (chosen, context, options) => { seen.push({ compat: chosen.compat }); return faux.provider.streamSimple(chosen, context, options); } };
  const models = createModels();
  models.setProvider(currentInstructions(watched));

  const cwd = await privateDir('omakase-instructions-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { models, model, invoke: railsStandIn().invoke,
    authorize: async scope => ({ ...scope, allowed: true, cwd }) });
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const send = async (requestId, instructions, tools) => {
    const sub = await runtime.submit(id, { ...scope, requestId, content: 'Who are you?', definition: definition({ instructions, ...(tools && { tools }) }) });
    await (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
  };

  await send('one', `${avery}\n\nBe brief.`);
  await send('two', `${avery}\n\nBe kind.`);
  await send('three', `${casey}\n\nBe kind.`);

  assert.equal(seen[0].compat?.supportsMidConvoSystemMessages, undefined, 'a first message is sent as the model takes it');
  assert.equal(seen[1].compat?.supportsMidConvoSystemMessages, undefined, 'an edit is appended: the cached prefix stays');
  assert.ok(seen[1].messages.filter(m => m.role === 'system').length > 1, 'pi-durable writes the edit as a later system message');
  assert.ok(changesIdentity(seen[2].messages));
  assert.equal(seen[2].compat.supportsMidConvoSystemMessages, false);
  const [leading, ...rest] = collapseSystemMessages({ messages: seen[2].messages }).messages;
  assert.match(getSystemMessageText(leading), /Casey Reyes\./);
  assert.doesNotMatch(getSystemMessageText(leading), /Avery/);
  assert.ok(rest.every(m => m.role !== 'system'));
  assert.match(getCurrentSystemPrompt(seen[2].messages), /Casey/);
});

test('only a new identity changes the model; tools and instructions under the same name do not', () => {
  const chosen = [];
  const provider = currentInstructions({ stream: model => chosen.push(model), streamSimple: model => chosen.push(model) });
  const model = { id: 'm', compat: { supportsMidConvoSystemMessages: true, supportsMidConvoToolChanges: true } };
  const baseline = { role: 'system', content: '', sections: { instructions: `${avery}\n\nBe brief.` } };
  const later = instructions => ({ role: 'system', content: '', sections: { instructions } });
  provider.stream(model, { messages: [baseline, { role: 'user', content: 'hi' }, { role: 'system', content: '', toolsAdded: [{ name: 'x' }] }] });
  provider.stream(model, { messages: [baseline, { role: 'user', content: 'hi' }, later(`${avery}\n\nBe kind.\n\n# Notes file\n\nMore.`)] });
  provider.streamSimple(model, { messages: [baseline, { role: 'user', content: 'hi' }, later(`${casey}\n\nBe kind.`)] });
  provider.streamSimple(model, { messages: [baseline, later(`${casey}\n\nBe kind.`), { role: 'user', content: 'hi' }, later(`${casey}\n\nBe brief.`)] });
  assert.equal(chosen[0], model);
  assert.equal(chosen[1], model, 'an edit, notes included, keeps the cache');
  assert.deepEqual(chosen[2].compat, { supportsMidConvoSystemMessages: false, supportsMidConvoToolChanges: true });
  assert.equal(chosen[3].compat.supportsMidConvoSystemMessages, false, 'compared with the leading prompt, not the update before');
  assert.equal(model.compat.supportsMidConvoSystemMessages, true, 'the catalogue model is not changed');
});
