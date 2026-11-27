import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chooseComputer, validNamedComputers } from '../named-computers.mjs';
import { boxdComputer } from '../boxd-computer.mjs';

const original = { provider: 'sprites', name: 'existing-prefix' };
const named = { pilot: { provider: 'boxd', name: 'pilot-one' } };
const scope = { actorId: 'fixture-person', workspaceId: 'fixture-agent' };
const enabled = { enabled: true, ...scope, machine: 'pilot-one' };

test('no name uses exactly the existing computer; an explicit unknown never falls back', () => {
  assert.equal(chooseComputer(original, named), original);
  assert.equal(chooseComputer(null, named), null);
  assert.throws(() => chooseComputer(original, named, 'other'), /unknown_computer/);
  assert.throws(() => chooseComputer(original, named, 'constructor'), /unknown_computer/);
  assert.equal(chooseComputer(original, named, 'pilot'), named.pilot);
});

test('boxd fails closed unless the explicitly scoped pilot is admitted', async () => {
  const client = { ensure: () => assert.fail('provider called without pilot admission') };
  for (const admission of [undefined, {}, { ...enabled, enabled: false }, { ...enabled, machine: 'not-the-pilot' }]) {
    const machine = boxdComputer({ admission, client });
    await assert.rejects(machine.env(named.pilot, scope), /boxd_unavailable/);
  }
  const machine = boxdComputer({ admission: enabled, client });
  await assert.rejects(machine.env(named.pilot, { ...scope, actorId: 'other' }), /boxd_unavailable/);
  await assert.rejects(machine.env(named.pilot, { ...scope, workspaceId: 'other' }), /boxd_unavailable/);
  await assert.rejects(machine.env({ ...named.pilot, held: true }, scope), /boxd_unavailable/);
});

test('several requests use one smallest machine with 15-minute hibernation', async () => {
  const requests = [];
  const offlineEnv = { cwd: '/workspace' };
  const machine = boxdComputer({ admission: enabled,
    client: { ensure: async request => { requests.push(request); return offlineEnv; } } });
  const results = await Promise.all([machine.env(named.pilot, scope), machine.env(named.pilot, scope)]);
  assert.deepEqual(results, [offlineEnv, offlineEnv]);
  assert.deepEqual(requests, [{ name: 'pilot-one', vcpus: 1, memoryMib: 4096, autoHibernateSeconds: 900 }]);
});

test('uncertain creation cannot start the same operation again', async () => {
  let calls = 0;
  const machine = boxdComputer({ admission: enabled, client: { ensure: async () => { calls += 1; throw new Error('unknown_outcome'); } } });
  await assert.rejects(machine.env(named.pilot, scope), /unknown_outcome/);
  await assert.rejects(machine.env(named.pilot, scope), /unknown_outcome/);
  assert.equal(calls, 1);
});

test('the declaration may name only one machine and does not carry transport settings', () => {
  assert.equal(validNamedComputers(named), true);
  assert.equal(validNamedComputers({ ...named, second: named.pilot }), false);
  assert.equal(validNamedComputers({ constructor: named.pilot }), false);
  assert.equal(validNamedComputers({ pilot: { ...named.pilot, host: 'fixture.example' } }), false);
});
