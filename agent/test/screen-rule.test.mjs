// One rule for every tool whose answer goes to the screen's browser (Rails'
// Tool.on_screen?: a saved sign-in's fill, a card's): it acts on the screen
// the agent's computer has. On a configured SSH computer that keeps its old
// Sprite for the screen, that is the Sprite `desktop` shows, as `browser`;
// never the SSH computer, where the agent's own processes would see the
// secret. With no screen, nothing runs anywhere.
import assert from 'node:assert/strict';
import test from 'node:test';
import { agentExtension } from '../extensions.mjs';

const FILLS = {
  sign_in_with_saved_password: { reply: { fill: true, result: { signIn: 'Bank' } }, script: '/opt/agent/fill.mjs', secret: 'AGENT_SIGN_IN' },
  pay_by_card: { reply: { pay: true, result: { card: 'Visa ending 4242' } }, script: '/opt/agent/pay.mjs', secret: 'AGENT_CARD' }
};

function call(tool, retainedScreen) {
  const sshRuns = [], screenRuns = [];
  const answer = (runs, argv, options) => {
    runs.push({ argv, env: options.env });
    options.onOutput(JSON.stringify({ ok: true, filled: ['password'], url: 'https://bank.example/login' }), {}, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  };
  const screen = retainedScreen && { id: 'sprites:as-test-b1-c3', onScreen: async (argv, options) => answer(screenRuns, argv, options) };
  const extension = agentExtension({ digest: 'd', tools: [{ name: tool, description: 'x', parameters: { type: 'object' } }] }, {
    invoke: async () => ({ status: 'done', isError: false, ...FILLS[tool].reply }),
    phoneForConversation: async () => false,
    signIn: async () => ({ host: 'bank.example', username: 'avery', password: 'synthetic-password' }),
    card: async () => ({ site: 'bank.example', number: '4000056655665556', exp_month: 12, exp_year: 2030 }), // gitleaks:allow (a test card)
    retainedScreen: async () => screen, invokeRetries: 0, invokeRetryMs: 1 });
  const env = { id: 'ssh:homeserver', cwd: '/srv/work/agent', exec: async (argv, options) => answer(sshRuns, argv, options) };
  const run = extension.tools[0].execute({}, { env, conversationId: 3, taskId: 7, callId: 'toolu_1', now: () => 0,
    snapshot: async () => ({ actorId: '1', workspaceId: '2', requests: {} }), commit: async () => {} }, {});
  return { run, sshRuns, screenRuns };
}

for (const [tool, { script, secret }] of Object.entries(FILLS)) {
  test(`${tool} on a retained browser runs on its Sprite as browser, never on the SSH computer`, async () => {
    const { run, sshRuns, screenRuns } = call(tool, true);
    const result = await run;
    assert.equal(result.isError, undefined, JSON.stringify(result));
    assert.deepEqual(screenRuns.map(it => it.argv), [['node', script]]);
    assert.deepEqual(Object.keys(screenRuns[0].env), [secret]);
    assert.deepEqual(sshRuns, []);
  });

  test(`${tool} with no screen runs nowhere`, async () => {
    const { run, sshRuns, screenRuns } = call(tool, false);
    assert.equal((await run).isError, true);
    assert.deepEqual([sshRuns, screenRuns], [[], []]);
  });
}

// A fill acts on the tab visit_website opened, so a retained browser visits there too.
test('visit_website on a retained browser opens the page on its Sprite as browser, never headless on the SSH computer', async () => {
  const { retainedVisit } = await import('../browser.mjs');
  assert.equal(typeof retainedVisit, 'function', 'a retained browser can visit');
  const screenRuns = [], sshRuns = [];
  const screen = { id: 'sprites:as-test-b1-c3', async onScreen(argv, options) {
    screenRuns.push(argv);
    options.onOutput(JSON.stringify({ title: 'Sign in', text: 'Bank', screenshot: 'AA==' }), {}, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  } };
  const env = { id: 'ssh:homeserver', cwd: '/srv/work/agent', exec: async argv => { sshRuns.push(argv); return { ok: false, error: { code: 'spawn_error' } }; } };
  const visit = screenFor => retainedVisit(screenFor).execute({ url: 'https://bank.example/login' }, { env }, {});
  const seen = await visit(async () => screen);
  assert.match(seen.output[0].text, /Title: Sign in/);
  assert.deepEqual(screenRuns, [['node', '/opt/agent/visit.mjs', 'https://bank.example/login']]);
  await assert.rejects(visit(async () => undefined), /retained screen is unavailable/);
  assert.deepEqual(sshRuns, []);
});
