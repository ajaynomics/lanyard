import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, readdirSync, symlinkSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { createServer as unixHttp } from 'node:http';
import { fileURLToPath } from 'node:url';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { sshComputers } from '../ssh-computers.mjs';
import { saveFile } from '../files.mjs';
import { createRuntime } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { eventually, privateDir } from './processes.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';

// A stand-in for `ssh`, run as pi-env runs it: the options, then `-- host`,
// then the command. It plays the machine's host key against the known-hosts
// file pi-env names, as OpenSSH does, and runs the command here, in the
// machine's stand-in home. Once the machine has an authorized_keys file, it
// lets in only the keys there, as sshd does. Everything else (pi-env's detection, the daemon's
// upload and hash check, the daemon itself) is real.
async function standIn(t) {
  const root = await privateDir('omakase-ssh-');
  const home = join(root, 'home'); await mkdir(home);
  const hostKey = () => {
    const file = join(root, `host-${Math.random().toString(36).slice(2)}`);
    execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-f', file]);
    return readFileSync(`${file}.pub`, "utf8").split(' ').slice(0, 2).join(' ');
  };
  const program = join(root, 'ssh');
  await writeFile(program, `#!/usr/bin/env bash
args=("$@")
# As OpenSSH does, everything after the host is the command, joined by spaces.
for ((i=0;i<\${#args[@]};i++)); do [ "\${args[i]}" = -- ] && { host="\${args[i+1]}"; command="\${args[*]:i+2}"; break; }; done
for a in "\${args[@]}"; do case "$a" in
  UserKnownHostsFile=*) known="\${a#*=}"; known="\${known//\\"/}" ;; StrictHostKeyChecking=*) strict="\${a#*=}" ;; HostKeyAlias=*) alias="\${a#*=}" ;;
  IdentityFile=*) identity="\${a#*=}"; identity="\${identity//\\"/}" ;;
esac; done
echo "$host as $(for ((i=0;i<\${#args[@]};i++)); do [ "\${args[i]}" = -l ] && echo "\${args[i+1]}"; done)" >> "${root}/destinations"
present=$(awk -v a="$alias" '$1==a {print $2" "$3}' "$known" 2>/dev/null)
key=$(cat "${root}/host-key")
if [ -z "$present" ]; then
  if [ "$strict" = accept-new ]; then echo "$alias $key" >> "$known"; else echo "Host key verification failed." >&2; exit 255; fi
elif [ "$present" != "$key" ]; then echo "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" >&2; exit 255; fi
if [ -f "${root}/authorized_keys" ] && ! grep -qxF "$(cut -d' ' -f1,2 "$identity.pub")" "${root}/authorized_keys"; then
  echo "jordan@$host: Permission denied (publickey)." >&2; exit 255; fi
# A machine may name its own PATH, to have a program or not.
[ -f "${root}/path" ] && PATH=$(cat "${root}/path")
cd "${home}" && HOME="${home}" exec sh -c "$command"
`, { mode: 0o755 });
  const machine = { root, home, program, dir: join(root, 'sidecar-ssh'),
    async presents(key) { await writeFile(join(root, 'host-key'), key); },
    async authorizes(key) { await writeFile(join(root, 'authorized_keys'), `${key.split(' ').slice(0, 2).join(' ')}\n`, { flag: 'a' }); },
    fingerprint(key) {
      const file = join(root, 'fp.pub'); writeFileSync(file, `${key}\n`);
      return execFileSync('ssh-keygen', ['-lf', file], { encoding: 'utf8' }).split(/\s+/)[1];
    },
    destinations: async () => (await readFile(join(root, 'destinations'), 'utf8')).trim().split('\n'),
    hostKey };
  await machine.presents(hostKey());
  return machine;
}
test('each person gets a key pair once, private to the sidecar, and sees its public half; the shared one is the original', async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const key = await computers.publicKey('person-1');
  assert.match(key, /^ssh-ed25519 AAAA\S+ durable-assistants$/);
  assert.equal(await computers.publicKey('person-1'), key);
  assert.notEqual(await computers.publicKey('person-2'), key);
  assert.equal((await stat(join(machine.dir, 'people', 'person-1', 'id_ed25519'))).mode & 0o777, 0o600);
  assert.equal((await stat(join(machine.dir, 'people', 'person-1'))).mode & 0o777, 0o700);
  const shared = await computers.publicKey('shared');
  assert.equal(`${shared}\n`, await readFile(join(machine.dir, 'id_ed25519.pub'), 'utf8'));
  for (const bad of [undefined, '', 'person-0', '../person-1', 'person-1/..', 'alice']) await assert.rejects(computers.publicKey(bad), /invalid_computer/, String(bad));
});

test("each agent has its own key pair, and a machine that let one agent's key in refuses another agent's", async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const first = { host: 'homeserver', user: 'jordan', folder: machine.home, keyring: 'agent-1' };
  const second = { ...first, keyring: 'agent-2' };
  const key = await computers.publicKey('agent-1');
  assert.notEqual(await computers.publicKey('agent-2'), key);
  assert.equal(`${key}\n`, await readFile(join(machine.dir, 'agents', 'agent-1', 'id_ed25519.pub'), 'utf8'));
  assert.equal((await stat(join(machine.dir, 'agents', 'agent-1', 'id_ed25519'))).mode & 0o777, 0o600);
  for (const bad of ['agent-0', 'agent-', '../agent-1', 'agent-1/..']) await assert.rejects(computers.publicKey(bad), /invalid_computer/, bad);

  await machine.authorizes(key);
  for (const where of [first, second]) await computers.trust(where, (await computers.hostKey(where)).fingerprints);
  const ran = await (await computers.env(first)).exec('echo hi', {}, ctx);
  assert.equal(ran.ok, true, ran.error?.message);
  const refused = await (await computers.env(second)).exec('echo hi', {}, ctx);
  assert.equal(refused.ok, false, "the second agent offers its own key, which the machine never saw");
  assert.match(refused.error.message, /Permission denied/);
});

test("one person's trusted host and key don't open the machine to another person's agent", async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const alice = { host: 'homeserver', user: 'alice', folder: machine.home, keyring: 'person-1' };
  const bob = { ...alice, keyring: 'person-2' };
  await computers.trust(alice, (await computers.hostKey(alice)).fingerprints);
  assert.equal((await computers.hostKey(alice)).trusted, true);
  assert.equal((await computers.hostKey(bob)).trusted, false, "Alice's trust is hers");

  assert.equal((await (await computers.env(alice)).exec('echo hi', {}, ctx)).ok, true);
  const refused = await (await computers.env(bob)).exec('echo hi', {}, ctx);
  assert.equal(refused.ok, false, "Bob's agent doesn't ride Alice's connection or trust");
  assert.match(refused.error.message, /not trusted/);
});

test('a host is trusted only as the person saw it, a changed key never replaces it, and nothing runs on an untrusted host', async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const where = { host: 'homeserver', user: 'jordan', folder: machine.home, keyring: 'person-1' };
  const presented = machine.fingerprint(await readFile(join(machine.root, 'host-key'), 'utf8'));

  const before = await computers.env(where);
  const refused = await before.exec('echo hi', {}, ctx);
  assert.equal(refused.ok, false);
  assert.match(refused.error.message, /not trusted/);

  assert.deepEqual(await computers.hostKey(where), { trusted: false, fingerprints: [presented] });
  await assert.rejects(computers.trust(where, ['SHA256:someone-elses']), /host_key_changed/);
  assert.deepEqual(await computers.trust(where, [presented]), { trusted: true, fingerprints: [presented] });
  assert.deepEqual(await computers.hostKey(where), { trusted: true, fingerprints: [presented] });

  const env = await computers.env(where);
  const ran = await env.exec('pwd > where.txt', {}, ctx);
  assert.equal(ran.ok, true, ran.error?.message);
  assert.equal(await readFile(join(machine.home, 'where.txt'), 'utf8'), `${machine.home}\n`);
  assert.ok((await machine.destinations()).every(line => line === 'homeserver as jordan'));

  const changed = machine.hostKey();
  await machine.presents(changed);
  // An open connection goes on; the next one, after a restart, is refused.
  const restarted = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => restarted.close());
  const later = await (await restarted.env(where)).exec('echo again', {}, ctx);
  assert.equal(later.ok, false, 'a changed key stops a new connection');
  assert.match(later.error.message, /CHANGED|changed/);
  await assert.rejects(computers.trust(where, [machine.fingerprint(changed)]), /host_key_changed/);
  assert.deepEqual((await computers.hostKey(where)).fingerprints, [presented], 'the trusted key stays');
});

test('an agent whose definition names a folder over SSH works there, and its command connectors run there too', async t => {
  const machine = await standIn(t);
  await mkdir(join(machine.home, 'work'));
  const cwd = await privateDir('omakase-ssh-bot-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ssh: { dir: machine.dir, ssh: machine.program } }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd > where.txt' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(() => runtime.close());
  assert.deepEqual({ ...runtime.offered }, { local: false, sprites: false, ssh: true });
  const where = { host: 'homeserver', user: 'jordan', keyring: 'person-1' };
  const { fingerprints } = await runtime.sshHost(where);
  await runtime.trustSshHost(where, fingerprints);

  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const folder = join(machine.home, 'work');
  const sub = await runtime.submit(id, { ...scope, requestId: 'shell', content: 'where are you?',
    definition: definition({ computer: { provider: 'ssh', ...where, folder } }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  assert.equal(await readFile(join(folder, 'where.txt'), 'utf8'), `${folder}\n`);
  await assert.rejects(readFile(join(cwd, String(id), 'where.txt')));

  // A command connector runs on the machine too, as the user, with plain pipes
  // through pi-env's daemon: a relative cwd is inside the agent's folder.
  await mkdir(join(folder, 'sub'));
  const entry = { command: process.execPath, args: [fileURLToPath(new URL('./stdio-mcp-server.mjs', import.meta.url))],
    env: { GREETING: 'hello' }, cwd: 'sub' };
  let next = 1;
  const rpc = async (method, params) => (await runtime.connector(id, 'files', { ...scope, computer: { provider: 'ssh', ...where, folder },
    entry, message: { jsonrpc: '2.0', id: `r${next++}`, method, params } })).message;
  const listed = await rpc('tools/list', {});
  assert.equal(listed.id, 'r1', "the reply comes back under Rails' id");
  assert.deepEqual(listed.result.tools.map(tool => tool.name), ['where', 'crash', 'slow']);
  const answer = JSON.parse((await rpc('tools/call', { name: 'where', arguments: {} })).result.content[0].text);
  assert.equal(answer.cwd, join(folder, 'sub'));
  assert.equal(answer.home, machine.home, "the user's own home, as in the agent's shell");
  assert.equal(answer.greeting, 'hello');
  assert.match((await rpc('tools/call', { name: 'crash', arguments: {} })).error.message, /exited: boom: the fixture crashed/);
  const again = JSON.parse((await rpc('tools/call', { name: 'where', arguments: {} })).result.content[0].text);
  assert.notEqual(again.pid, answer.pid, 'started again after it died');
});

test('a configured SSH descriptor uses only the sealed keyring, with strict host verification', async t => {
  const machine = await standIn(t);
  const keyring = 'configured-review';
  const folder = join(machine.home, 'agent-slug');
  const where = { provider: 'ssh', host: 'homeserver', user: 'jordan', folder, keyring };
  const ring = join(machine.dir, 'configured', keyring);
  const identity = join(ring, 'id_ed25519');
  const opts = { dir: machine.dir, ssh: machine.program };
  const computers = sshComputers(opts);
  t.after(() => computers.close());
  await mkdir(folder);
  await assert.rejects(computers.env(where), /configured_ssh_unavailable/);
  await assert.rejects(stat(ring), { code: 'ENOENT' });
  await mkdir(ring, { recursive: true, mode: 0o700 });
  await writeFile(identity, 'synthetic identity for the stand-in', { mode: 0o600 });
  const known = join(ring, 'known_hosts');
  await assert.rejects(computers.env(where), /configured_ssh_unavailable/);
  await writeFile(known, '');
  const untrusted = await (await computers.env(where)).exec('pwd', {}, ctx);
  assert.equal(untrusted.ok, false);
  assert.match(untrusted.error.message, /not trusted/);
  assert.equal(await readFile(known, 'utf8'), '');
  const hostKey = await readFile(join(machine.root, 'host-key'), 'utf8');
  await writeFile(known, `pi-env-homeserver ${hostKey}\n`);
  await assert.rejects(computers.publicKey(keyring), /invalid_computer/);
  await assert.rejects(computers.hostKey(where), /invalid_computer/);
  await assert.rejects(computers.trust(where, []), /invalid_computer/);

  let configuredSsh = where;
  const runtime = await createRuntime({ storePath: join(machine.root, 'state.sqlite'), ssh: opts }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd > where.txt' }), { stopReason: 'toolUse' }), message('done'),
      message(call('bash', { command: 'pwd > revoked.txt' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd: machine.root, configuredSsh }),
    invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'configured-shell', content: 'where are you?',
    definition: definition({ computer: where }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  assert.equal(await readFile(join(folder, 'where.txt'), 'utf8'), `${folder}\n`);

  configuredSsh = undefined;
  const stale = await runtime.submit(id, { ...scope, requestId: 'stale-configured-shell', content: 'where are you now?',
    definition: definition({ computer: where }) });
  await (await runtime.harness.submission(stale.id, ctx)).wait(ctx);
  await assert.rejects(stat(join(folder, 'revoked.txt')), { code: 'ENOENT' }, 'a stale definition cannot reach the host');

  await machine.presents(machine.hostKey());
  const restarted = sshComputers(opts);
  t.after(() => restarted.close());
  const changed = await (await restarted.env(where)).exec('pwd', {}, ctx);
  assert.equal(changed.ok, false);
  assert.match(changed.error.message, /changed/i);
  assert.equal(await readFile(known, 'utf8'), `pi-env-homeserver ${hostKey}\n`);
});

test('Stop ends a configured SSH command but keeps admitted messages for the next delivery', async t => {
  const machine = await standIn(t);
  const folder = join(machine.home, 'agent-slug');
  const keyring = 'configured-review';
  const ring = join(machine.dir, 'configured', keyring);
  await mkdir(folder);
  await mkdir(ring, { recursive: true });
  await writeFile(join(ring, 'id_ed25519'), 'synthetic identity for the stand-in', { mode: 0o600 });
  await writeFile(join(ring, 'known_hosts'), `pi-env-homeserver ${await readFile(join(machine.root, 'host-key'), 'utf8')}\n`);
  const where = { provider: 'ssh', host: 'homeserver', user: 'jordan', folder, keyring };
  const sidecarToken = 'synthetic-fixture-sidecar';
  const sidecar = await createServer({ sidecarToken, storePath: join(machine.root, 'state.sqlite'),
    ssh: { dir: machine.dir, ssh: machine.program } }, {
    ...scriptedProvider([
      message(call('bash', { command: "sleep 120 & printf '%s %s %s\\n' \"$PPID\" \"$$\" \"$!\" > started; wait" }), { stopReason: 'toolUse' }),
      message(call('bash', { command: 'echo "$PPID" > next-daemon; while [ ! -f finish ]; do sleep 0.05; done', timeout: 10 }), { stopReason: 'toolUse' }),
      message('finished the waiting work')
    ]),
    authorize: async scope => ({ ...scope, allowed: true, cwd: machine.root, configuredSsh: where }),
    invoke: railsStandIn().invoke, onComputerLog: () => {}
  });
  t.after(() => sidecar.close());
  assert.deepEqual(sidecar.readiness(), { ready: true });
  const { port } = await sidecar.listen(0);
  const runtime = sidecar.runtime;
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const submit = (requestId, whenBusy, extra) => runtime.submit(id, { ...scope, requestId, content: requestId, whenBusy, ...extra });
  const get = sub => runtime.harness.submission(sub.id, ctx);
  const active = await submit('shell', undefined, { definition: definition({ computer: where }) });
  const readMarker = async (name, pattern) => eventually(async () => {
    const marker = await readFile(join(folder, name), 'utf8').catch(error => { if (error.code !== 'ENOENT') throw error; });
    return pattern.test(marker ?? '') && marker;
  });
  const [daemon, shell, child] = (await readMarker('started', /^\d+ \d+ \d+\n$/)).trim().split(' ').map(Number);
  const steer = await submit('waiting-steer', 'steer');
  const follow = await submit('waiting-follow-up', 'followUp');
  assert.equal(steer.status, 'queued');
  assert.equal(follow.status, 'queued');

  const stop = async () => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/conversations/${id}/cancellations`, {
      method: 'POST', headers: { authorization: `Bearer ${sidecarToken}`, 'content-type': 'application/json' },
      body: JSON.stringify({ ...scope, requestId: 'stop', preserveQueue: true })
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { cancelled: true });
  };
  await stop();
  const stopped = await (await get(active)).status(ctx);
  assert.deepEqual([stopped.status, stopped.reason], ['unanswered', 'aborted']);
  for (const pid of [shell, child]) await eventually(async () => {
    const status = await readFile(`/proc/${pid}/status`, 'utf8').catch(error => { if (error.code !== 'ENOENT') throw error; });
    return status === undefined || /^State:\s+Z/m.test(status);
  });
  const queued = await Promise.all([steer, follow].map(async sub => {
    const { status, reason } = await (await get(sub)).status(ctx);
    return reason ? `${status}:${reason}` : status;
  }));
  assert.deepEqual(queued, ['queued', 'queued']);

  const next = await submit('next-delivery');
  assert.equal(await readMarker('next-daemon', /^\d+\n$/), `${daemon}\n`, 'same SSH tool daemon');
  await stop(); // Same Stop request ID must not touch the newer work.
  await writeFile(join(folder, 'finish'), '');
  for (const sub of [steer, follow, next]) assert.equal((await (await get(sub)).wait(ctx)).status, 'done');
  const entries = (await runtime.entries(id, scope)).entries;
  assert.deepEqual(entries.filter(entry => entry.role === 'user').map(entry => entry.content),
    ['shell', 'waiting-steer', 'waiting-follow-up', 'next-delivery']);
});

// A configured SSH machine whose keyring is in place, for file saves.
async function configured(t) {
  const machine = await standIn(t);
  const keyring = 'configured-review', folder = join(machine.home, 'agent-slug'), ring = join(machine.dir, 'configured', keyring);
  await mkdir(folder);
  await mkdir(ring, { recursive: true });
  await writeFile(join(ring, 'id_ed25519'), 'synthetic identity for the stand-in', { mode: 0o600 });
  await writeFile(join(ring, 'known_hosts'), `pi-env-homeserver ${await readFile(join(machine.root, 'host-key'), 'utf8')}\n`);
  return { machine, folder, where: { provider: 'ssh', host: 'homeserver', user: 'jordan', folder, keyring } };
}

test('a mapped visit uses the existing SSH runner and requires the live computer binding', async t => {
  const { machine, where } = await configured(t);
  const root = await privateDir('sandbox-sockets-');
  await mkdir(join(root, 'avery'));
  const touched = [];
  const act = unixHttp((request, response) => {
    touched.push([request.method, request.url]);
    response.writeHead(503).end();
  });
  await new Promise(resolve => act.listen(join(root, 'avery', 'act.sock'), resolve));
  t.after(() => act.close());
  const bin = join(machine.root, 'test-bin');
  await mkdir(bin);
  await writeFile(join(bin, 'chromium'), '#!/bin/sh\nexit 127\n', { mode: 0o755 });
  await writeFile(join(machine.root, 'path'), `${bin}:${dirname(process.execPath)}:/usr/bin:/bin`);
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const url = 'https://example.test/';
  let ssh = { ...where, user: 'wrong' };
  const runtime = await createRuntime({ storePath: join(machine.root, 'state.sqlite'), ssh: { dir: machine.dir, ssh: machine.program } }, {
    ...scriptedProvider([
      message(call('visit_website', { url }), { stopReason: 'toolUse' }), message('first done'),
      message(call('visit_website', { url }), { stopReason: 'toolUse' }), message('second done')
    ]),
    authorize: async asked => ({ ...scope, allowed: true, cwd: machine.root, configuredSsh: where,
      ...(asked.sandboxBrowser ? { sandboxBrowser: { name: 'avery', conversationId: asked.conversationId, ssh } } : {}) }),
    invoke: railsStandIn().invoke, onComputerLog: () => {}, sandboxBrowserRoot: root
  });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async requestId => {
    const sub = await runtime.submit(id, { ...scope, requestId, content: requestId,
      definition: definition({ computer: { ...where, sandboxBrowser: true } }) });
    assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  };
  await run('mismatched-binding');
  assert.deepEqual(touched, [], 'the remembered computer must match Rails before touching the socket');
  ssh = where;
  await run('mapped-route');
  assert.deepEqual(touched, [['POST', '/open']]);
});

// Every kind of file a tool saves (files.mjs saveFile) lands in the configured
// SSH computer's own folder, as on a Sprite it lands in its home.
test('each file a tool saves goes to the configured SSH computer\'s folder', async t => {
  const { machine, folder, where } = await configured(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const env = await computers.env(where);
  const BYTES = Buffer.from('synthetic file bytes');
  const cases = {
    'a Gmail attachment': ['mcp__gmail__get_attachment', { message_id: 'm1', file: { name: 'invoice.txt', type: 'text/plain', size: BYTES.length } }],
    'an iMessage attachment': ['imessage_attachment', { attachment: 'at_1', file: { name: 'photo.jpg', type: 'image/jpeg', size: BYTES.length } }],
    'a Drive file read': ['mcp__drive__read_file', { file: { name: 'plan.pdf', type: 'application/pdf', size: BYTES.length } }],
    'a connector answer over the limit': ['mcp__records__search', { text: 'Line 0', found_files: [{ name: 'search-answer.txt', type: 'text/plain', size: BYTES.length, held: 0 }] }]
  };
  for (const [kind, [tool, result]] of Object.entries(cases)) await t.test(kind, async () => {
    const answer = JSON.parse((await saveFile(async () => BYTES, { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: tool, tool },
      result, { env }, ctx)).output[0].text);
    const saved = answer.found_files?.[0].saved ?? answer.saved;
    assert.match(saved ?? answer.note, new RegExp(`^${folder}/files/[0-9a-f]{10}/`));
    assert.deepEqual(await readFile(saved), BYTES);
  });
});

test('an email\'s attachments are saved on the configured SSH computer too', async t => {
  const { machine, folder, where } = await configured(t);
  const runtime = await createRuntime({ storePath: join(machine.root, 'state.sqlite'), ssh: { dir: machine.dir, ssh: machine.program } }, {
    ...scriptedProvider([]), authorize: async scope => ({ ...scope, allowed: true, cwd: machine.root, configuredSsh: where }),
    invoke: railsStandIn().invoke, fetchFile: async () => Buffer.from('statement'), onComputerLog: () => {} });
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const { files } = await runtime.saveFiles(id, { ...scope, computer: where, taskId: 'email', callId: 'mail-1',
    files: [{ name: 'statement.txt', type: 'text/plain', size: 9, held: 0 }] });
  assert.match(files[0].saved ?? files[0].note, new RegExp(`^${folder}/files/`));
  assert.equal(await readFile(files[0].saved, 'utf8'), 'statement');
});

// The Sprite's reader's commands (guest/pdf-text.mjs), as stand-ins: pdftotext's
// text layer with a second page that has none, which tesseract reads.
const READERS = {
  pdftotext: 'printf "Statement for March\\f\\f"',
  pdftoppm: 'for last; do :; done; : > "$last.png"',
  tesseract: 'echo "Scanned total 42"'
};

// A PATH with every program of the machine's but the PDF reader's, and the
// stand-ins first when the reader is there.
function machinePath(machine, reader) {
  const bin = join(machine.root, 'bin');
  mkdirSync(bin);
  for (const name of readdirSync('/usr/bin')) if (!(name in READERS)) symlinkSync(join('/usr/bin', name), join(bin, name));
  if (reader) for (const [name, body] of Object.entries(READERS)) writeFileSync(join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
  writeFileSync(join(machine.root, 'path'), `${bin}:${dirname(process.execPath)}`);
}

for (const reader of [true, false]) test(`a PDF saved on a configured SSH computer ${reader ? 'is read there, as on a Sprite' : 'without a reader is saved, not read'}`, async t => {
  const { machine, folder, where } = await configured(t);
  machinePath(machine, reader);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const answer = JSON.parse((await saveFile(async () => Buffer.from('%PDF-1.4'), { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7,
    callId: 'pdf', tool: 'mcp__drive__read_file' }, { file: { name: 'statement.pdf', type: 'application/pdf', size: 8 } },
    { env: await computers.env(where) }, ctx)).output[0].text);
  assert.match(answer.saved, new RegExp(`^${folder}/files/[0-9a-f]{10}/statement\\.pdf$`));
  if (!reader) return assert.match(answer.note, /^Saved, but its words could not be read: this computer has no PDF reader/);
  const words = '--- page 1 ---\nStatement for March\n\n--- page 2 ---\nScanned total 42';
  assert.deepEqual([answer.text, answer.pages, answer.read_by_ocr, answer.full_text], [words, 2, [2], `${answer.saved}.txt`]);
  assert.equal(await readFile(answer.full_text, 'utf8'), words);
});
