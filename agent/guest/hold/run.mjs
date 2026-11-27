import { chmodSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { join } from 'node:path';
import { once } from 'node:events';
import { Decision } from './decision.mjs';
import { fromPage, HeldRequest } from './held-request.mjs';
import { RequestReader, refuse } from './request-reader.mjs';
import { SiteCertificates } from './site-certificates.mjs';
import { ThrowawayAuthority } from './throwaway-authority.mjs';
import { Tunnel } from './tunnel.mjs';
import { Upstream } from './upstream.mjs';
import { decisionKey, MUTATIONS } from './wire.mjs';

const runtime = '/dev/shm/browser-hold';
if (!process.getuid()) throw new Error('hold proxy refuses root');
process.umask(0o077);
const credential = join(runtime, 'private/relay-key');
const secret = readFileSync(credential);
rmSync(credential);
if (secret.length < 32) throw new Error('hold relay secret missing');
const decision = new Decision(decisionKey(secret));
secret.fill(0);
const authority = new ThrowawayAuthority(join(runtime, 'private'));
const upstream = new Upstream();
const relay = createServer(socket => decision.attach(socket));
const relayPath = join(runtime, 'relay.sock');
relay.listen(relayPath);
await once(relay, 'listening');
chmodSync(relayPath, 0o660);

const tunnel = new Tunnel(new SiteCertificates(authority), new RequestReader(async (request, response, site, signal) => {
  if (MUTATIONS.has(request.method)) {
    if (!fromPage(request.headers)) return void refuse(response, 'browser write not from a page');
    const held = new HeldRequest(site.site, request);
    if (!await decision.wait(held.ticket, signal)) return void (!response.destroyed && refuse(response));
  }
  await upstream.send(site, request, response, signal);
}));
tunnel.listen(18181);
await once(tunnel.server, 'listening');
writeFileSync(join(runtime, 'private/ready'), String(process.pid));
