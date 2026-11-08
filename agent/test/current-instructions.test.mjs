import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { collapseSystemMessages, getCurrentSystemPrompt } from '@earendil-works/pi-ai/utils/transcript';
import { getSystemMessageText } from '@earendil-works/pi-ai/utils/text';
import { createRuntime } from '../runtime.mjs';
import { currentInstructions, changesInstructions } from '../current-instructions.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

// An agent renamed in its instructions: Rails sends the new definition with
// the next message, and the model must read the new instructions as its
// prompt, not as an update under the old one.
test('changed instructions lead the next request in place of the old, and only then is the prompt rebuilt', async t => {
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

  await send('one', 'You are Durable Assistants.');
  await send('two', 'You are Casey Reyes.');

  assert.equal(seen[0].compat?.supportsMidConvoSystemMessages, undefined, 'a first message is sent as the model takes it');
  assert.ok(changesInstructions(seen[1].messages), 'pi-durable writes the change as a later system message');
  assert.equal(seen[1].compat.supportsMidConvoSystemMessages, false);
  const [leading, ...rest] = collapseSystemMessages({ messages: seen[1].messages }).messages;
  assert.match(getSystemMessageText(leading), /You are Casey Reyes\./);
  assert.doesNotMatch(getSystemMessageText(leading), /Avery/);
  assert.ok(rest.every(m => m.role !== 'system'));
  assert.match(getCurrentSystemPrompt(seen[1].messages), /Casey/);
});

test('a request without an instructions change keeps the model as it is', () => {
  const chosen = [];
  const provider = currentInstructions({ stream: model => chosen.push(model), streamSimple: model => chosen.push(model) });
  const model = { id: 'm', compat: { supportsMidConvoSystemMessages: true, supportsMidConvoToolChanges: true } };
  const baseline = { role: 'system', content: '', sections: { instructions: 'Be brief.' } };
  provider.stream(model, { messages: [baseline, { role: 'user', content: 'hi' }, { role: 'system', content: '', toolsAdded: [{ name: 'x' }] }] });
  provider.streamSimple(model, { messages: [baseline, { role: 'user', content: 'hi' }, { role: 'system', content: '', sections: { instructions: 'Be kind.' } }] });
  assert.equal(chosen[0], model);
  assert.deepEqual(chosen[1].compat, { supportsMidConvoSystemMessages: false, supportsMidConvoToolChanges: true });
  assert.equal(model.compat.supportsMidConvoSystemMessages, true, 'the catalogue model is not changed');
});
