// An agent's computer as a folder on a real machine, reached over SSH: the
// agent works there as one Unix user, as a person does in a terminal. Nothing
// isolates it from what that user can reach, which is the point and the risk
// (docs/computers.md): Rails offers it only where the install lists it, and
// the person turns it on for one agent at a time.
//
// pi-env does the SSH (agent/node_modules/@earendil-works/pi-env): strict
// host keys against our own known-hosts file, no forwarding, no prompts, and
// its daemon put on the machine and checked by its hash before every start.
// This holds the sidecar's one key pair, made on first use, and the hosts the
// person has trusted, both in its own folder in storage.
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { mkdir, readFile, access } from 'node:fs/promises';
import { RemoteExecutionEnv, sshConnection, scanHostKey, acceptHostKey, HostKeyChangedError } from '@earendil-works/pi-env';

// A host name or IPv4 address, a Unix user name, and an absolute folder with
// no `..`; what Rails validates (Computer) and the sidecar checks again.
export const SSH_HOST = /^[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?$/i;
export const SSH_USER = /^[a-z_][a-z0-9_-]{0,31}$/;
export const validFolder = folder => typeof folder === 'string' && folder.length <= 1024 && folder.startsWith('/') &&
  !/[\0\n\r]/.test(folder) && !folder.split('/').includes('..');
export const validSsh = ({ host, user, folder }) =>
  typeof host === 'string' && SSH_HOST.test(host) && typeof user === 'string' && SSH_USER.test(user) && validFolder(folder);

const run = (program, args) => new Promise((resolve, reject) => {
  const child = spawn(program, args, { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', err = '';
  child.stdout.setEncoding('utf8').on('data', text => { out += text; });
  child.stderr.setEncoding('utf8').on('data', text => { err = (err + text).slice(-2000); });
  child.on('error', reject);
  child.on('close', code => code === 0 ? resolve(out) : reject(new Error(err.trim() || `${program} exited ${code}`)));
});

// `ssh`, for tests, is the program pi-env runs in its place.
export function sshComputers({ dir, ssh, onLog } = {}) {
  if (!dir) throw new Error('ssh_dir_required');
  const identityFile = join(dir, 'id_ed25519');
  const knownHostsFile = join(dir, 'known_hosts');
  const target = ({ host, user }) => {
    if (!SSH_HOST.test(host ?? '') || !SSH_USER.test(user ?? '')) throw new Error('invalid_computer');
    return { host, user, identityFile, knownHostsFile, hostKeyAlias: `pi-env-${host}`, ...(ssh ? { ssh } : {}) };
  };
  let made;
  const ensureKey = () => made ??= (async () => {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    try { await access(identityFile); } catch {
      await run('ssh-keygen', ['-q', '-t', 'ed25519', '-N', '', '-C', 'durable-assistants', '-f', identityFile]);
    }
  })().catch(error => { made = undefined; throw error; });
  const connections = new Map();

  return {
    // The public half, for the person to add to the user's authorized_keys.
    async publicKey() {
      await ensureKey();
      return (await readFile(`${identityFile}.pub`, 'utf8')).trim();
    },
    // Whether the host's key is trusted, with its fingerprints: the trusted
    // ones, or what the host presents now, for the person to compare with
    // ones they got another way before trusting it.
    async hostKey(where) {
      const at = target(where);
      let trusted = '';
      try { trusted = await run('ssh-keygen', ['-l', '-F', at.hostKeyAlias, '-f', knownHostsFile]); } catch {}
      const fingerprints = trusted.split('\n').filter(line => line.trim() && !line.startsWith('#'))
        .map(line => line.trim().split(/\s+/).find(part => part.startsWith('SHA256:'))).filter(Boolean);
      if (fingerprints.length) return { trusted: true, fingerprints };
      return { trusted: false, fingerprints: (await scanHostKey(at)).fingerprints.map(line => line.split(/\s+/)[1]) };
    },
    // Trusts the host's key only if it is still the one the person saw. A
    // key that changed from a trusted one is never replaced here.
    async trust(where, seen) {
      const at = target(where);
      const { lines, fingerprints } = await scanHostKey(at);
      const now = fingerprints.map(line => line.split(/\s+/)[1]).sort();
      if (!Array.isArray(seen) || JSON.stringify([...seen].sort()) !== JSON.stringify(now)) throw new Error('host_key_changed');
      await mkdir(dir, { recursive: true, mode: 0o700 });
      try { await acceptHostKey(at, lines); } catch (error) {
        throw error instanceof HostKeyChangedError ? new Error('host_key_changed') : error;
      }
      return { trusted: true, fingerprints: now };
    },
    // The agent works in its folder. One connection per user and host; it
    // starts on the first operation and again after a failed one.
    async env({ host, user, folder }) {
      if (!validFolder(folder)) throw new Error('invalid_computer');
      const at = target({ host, user });
      await ensureKey();
      const id = `${user}@${host}`;
      if (!connections.has(id)) connections.set(id, sshConnection({ ...at, onLog }).connection);
      return new RemoteExecutionEnv({ connection: connections.get(id), id: `ssh:${id}`, cwd: folder });
    },
    close() { for (const connection of connections.values()) connection.close(); connections.clear(); }
  };
}
