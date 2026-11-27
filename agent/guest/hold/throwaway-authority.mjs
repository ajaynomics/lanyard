import { execFileSync } from 'node:child_process';
import { readFileSync, rmSync, statfsSync } from 'node:fs';
import { join } from 'node:path';

export class ThrowawayAuthority {
  constructor(directory) {
    if (statfsSync(directory).type !== 0x01021994) throw new Error('CA requires tmpfs');
    this.cert = join(directory, 'root.pem');
    this.directory = directory;
    const key = join(directory, 'root.key');
    try {
      execFileSync('openssl', ['req', '-new', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
        '-noenc', '-days', '30', '-subj', '/CN=Browser Hold Local Authority',
        '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        '-out', this.cert, '-keyout', key], { stdio: 'ignore', timeout: 5000 });
      this.key = readFileSync(key);
    } finally {
      rmSync(key, { force: true });
    }
  }
}
