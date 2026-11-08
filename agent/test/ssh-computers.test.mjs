import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdir, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { sshComputers } from '../ssh-computers.mjs';
import { createRuntime } from '../runtime.mjs';
import { privateDir } from './processes.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';

// A stand-in for `ssh`, run as pi-env runs it: the options, then `-- host`,
// then the command. It plays the machine's host key against the known-hosts
// file pi-env names, as OpenSSH does, and runs the command here, in the
// machine's stand-in home. Everything else (pi-env's detection, the daemon's
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
esac; done
echo "$host as $(for ((i=0;i<\${#args[@]};i++)); do [ "\${args[i]}" = -l ] && echo "\${args[i+1]}"; done)" >> "${root}/destinations"
present=$(awk -v a="$alias" '$1==a {print $2" "$3}' "$known" 2>/dev/null)
key=$(cat "${root}/host-key")
if [ -z "$present" ]; then
  if [ "$strict" = accept-new ]; then echo "$alias $key" >> "$known"; else echo "Host key verification failed." >&2; exit 255; fi
elif [ "$present" != "$key" ]; then echo "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" >&2; exit 255; fi
cd "${home}" && HOME="${home}" exec sh -c "$command"
`, { mode: 0o755 });
  const machine = { root, home, program, dir: join(root, 'sidecar-ssh'),
    async presents(key) { await writeFile(join(root, 'host-key'), key); },
    fingerprint(key) {
      const file = join(root, 'fp.pub'); writeFileSync(file, `${key}\n`);
      return execFileSync('ssh-keygen', ['-lf', file], { encoding: 'utf8' }).split(/\s+/)[1];
    },
    destinations: async () => (await readFile(join(root, 'destinations'), 'utf8')).trim().split('\n'),
    hostKey };
  await machine.presents(hostKey());
  return machine;
}
test('the sidecar makes its key pair once, private to it, and shows the public half', async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const key = await computers.publicKey();
  assert.match(key, /^ssh-ed25519 AAAA\S+ durable-assistants$/);
  assert.equal(await computers.publicKey(), key);
  assert.equal((await stat(join(machine.dir, 'id_ed25519'))).mode & 0o777, 0o600);
  assert.equal((await stat(machine.dir)).mode & 0o777, 0o700);
});

test('a host is trusted only as the person saw it, a changed key never replaces it, and nothing runs on an untrusted host', async t => {
  const machine = await standIn(t);
  const computers = sshComputers({ dir: machine.dir, ssh: machine.program });
  t.after(() => computers.close());
  const where = { host: 'homeserver', user: 'jordan', folder: machine.home };
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

test('an agent whose definition names a folder over SSH works there, with no command connectors there yet', async t => {
  const machine = await standIn(t);
  await mkdir(join(machine.home, 'work'));
  const cwd = await privateDir('omakase-ssh-bot-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ssh: { dir: machine.dir, ssh: machine.program } }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd > where.txt' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(() => runtime.close());
  assert.deepEqual({ ...runtime.offered }, { local: false, sprites: false, ssh: true });
  const where = { host: 'homeserver', user: 'jordan' };
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
  await assert.rejects(runtime.connector(id, 'files', { ...scope, computer: { provider: 'ssh', ...where, folder },
    entry: { command: 'mcp-files' }, message: { jsonrpc: '2.0', id: 1, method: 'tools/list' } }), /computer_unavailable/);
});
