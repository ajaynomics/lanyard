// A tiny stdio MCP server for tests: newline-delimited JSON-RPC answering
// initialize, tools/list and tools/call. `where` tells which process answered
// and with what folder and GREETING; `crash` writes to stderr and exits.
import { createInterface } from 'node:readline';

let initialized = false;
const reply = (id, result) => process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id, result })}\n`);
const tools = [
  { name: 'where', description: 'Says where it runs.', inputSchema: { type: 'object', properties: {} }, annotations: { readOnlyHint: true } },
  { name: 'crash', description: 'Exits.', inputSchema: { type: 'object', properties: {} } }
];

createInterface({ input: process.stdin }).on('line', line => {
  const message = JSON.parse(line);
  if (message.method === 'initialize') {
    if (initialized) throw new Error('initialized twice');
    initialized = true;
    return reply(message.id, { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'fixture', version: '1' } });
  }
  if (message.id === undefined) return;
  if (!initialized) return process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32002, message: 'not initialized' } })}\n`);
  if (message.method === 'tools/list') return reply(message.id, { tools });
  if (message.method === 'tools/call' && message.params.name === 'where') {
    const text = JSON.stringify({ pid: process.pid, cwd: process.cwd(), home: process.env.HOME, greeting: process.env.GREETING ?? null });
    return reply(message.id, { content: [{ type: 'text', text }] });
  }
  if (message.method === 'tools/call' && message.params.name === 'crash') {
    process.stderr.write('boom: the fixture crashed\n');
    process.exit(3);
  }
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } })}\n`);
});
