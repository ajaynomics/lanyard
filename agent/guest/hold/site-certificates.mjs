import { execFile } from 'node:child_process';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { isIP } from 'node:net';
import { join } from 'node:path';

// OpenSSL opens its key by filename. A real pipe here (not Node's stdio
// socketpair) gives it a file descriptor without ever recreating the CA key.
function openssl(key, args) {
  return new Promise((resolve, reject) => {
    const child = execFile('/bin/sh', ['-c', 'cat | exec openssl "$@"', 'openssl', ...args],
      { encoding: 'buffer', timeout: 5000 }, (error, out) => error ? reject(new Error('certificate could not be made')) : resolve(out));
    child.stdin.on('error', () => {});
    child.stdin.end(key);
  });
}

export class SiteCertificates {
  #cache = new Map();
  constructor(authority) { this.authority = authority; }

  forSite(host) {
    const previous = this.#cache.get(host);
    if (previous?.expires > Date.now()) return previous.pair;
    if (this.#cache.size >= 64) this.#cache.delete(this.#cache.keys().next().value);
    const pair = this.#make(host).catch(error => { this.#cache.delete(host); throw error; });
    this.#cache.set(host, { pair, expires: Date.now() + 12 * 60 * 60 * 1000 });
    return pair;
  }

  async #make(host) {
    const { privateKey: key } = generateKeyPairSync('ec', { namedCurve: 'P-256', privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
      publicKeyEncoding: { type: 'spki', format: 'pem' } });
    const dir = await mkdtemp(join(this.authority.directory, 'leaf-'));
    try {
      const csr = join(dir, 'request.pem');
      await writeFile(csr, await openssl(key, ['req', '-new', '-key', '/dev/stdin', '-subj', '/CN=Browser Hold Site',
        '-addext', 'subjectAltName=' + (isIP(host) ? 'IP:' : 'DNS:') + host, '-addext', 'extendedKeyUsage=serverAuth']));
      const cert = await openssl(this.authority.key, ['x509', '-req', '-days', '1', '-in', csr, '-CA', this.authority.cert,
        '-CAkey', '/dev/stdin', '-set_serial', '0x' + randomBytes(16).toString('hex'), '-copy_extensions', 'copy']);
      return { key, cert };
    } finally { await rm(dir, { recursive: true, force: true }); }
  }
}
