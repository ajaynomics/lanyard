import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { McpClient, StdioTransport, StreamableHttpTransport, toLlmContent } from '@earendil-works/pi-mcp';
import { App, scopeMatches } from './state.mjs';


// Each client belongs to one explicit actor/workspace/account. There is no auth
// discovery, HOME lookup or model-controlled selection of transport/account.
// A server with `requireGrant: true` also needs a persisted Rails grant for that
// actor/workspace/server/account (`grant` reads it); a revocation persists.
export async function connectMcp(configs, { fetch: fetchTransport = fetch, grant } = {}) {
  const clients = [];
  const extensions = [];
  const advertised = [];
  try {
    for (const config of configs) {
      if (!config.actorId || !config.workspaceId || !config.accountId || !config.serverId || !Array.isArray(config.tools) ||
        !/^[a-zA-Z0-9_]{1,16}$/.test(config.serverId)) throw new Error('invalid_mcp_scope');
      const client = new McpClient({ name: 'omakase', version: '1', requestTimeoutMs: config.timeoutMs ?? 30000 });
      clients.push(client);
      const transport = config.stdio ? new StdioTransport({ command: config.stdio.command,
        args: config.stdio.args ?? [], inheritEnv: false, env: { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', ...(config.stdio.env ?? {}) } }) :
        new StreamableHttpTransport({ url: config.url, headers: config.headers ?? {}, fetch: fetchTransport });
      await client.connect(transport);
      const discovered = await client.listTools();
      advertised.push({ client, config });
      const tools = discovered.filter(tool => config.tools.includes(tool.name)).map(tool => defineTool({
        name: `mcp__${config.serverId}__${tool.name}`.replace(/[^A-Za-z0-9_-]/g, '_'),
        description: tool.description ?? tool.name,
        // The server's own JSON Schema, passed through as plain JSON Schema.
        parameters: { ...tool.inputSchema, type: 'object', properties: tool.inputSchema?.properties ?? {} },
        ...(tool.outputSchema ? { structuredOutputSchema: tool.outputSchema } : {}),
        // Offered only once tool_search loads it (see runtime.mjs).
        ...(config.deferTools === true ? { deferred: true } : {}),
        execute: async (args, api, ctx) => {
          const scope = await api.snapshot(App, api.conversationId, ctx);
          if (!scopeMatches(scope, config) || config.revoked === true || !config.tools.includes(tool.name)) throw new Error('mcp_scope_denied');
          if (config.requireGrant === true && (typeof grant !== 'function' || await grant(scope, config) !== 'granted')) throw new Error('mcp_grant_missing');
          let progressEvents = 0;
          const result = await client.callTool(tool.name, args, { signal: ctx.abortSignal,
            onProgress: progress => { progressEvents++; api.output(JSON.stringify({ progress: progress.progress, total: progress.total }) + '\n'); } });
          return { output: toLlmContent(result), isError: result.isError === true,
            ...(tool.outputSchema && result.structuredContent !== undefined ? { structuredOutput: result.structuredContent } : {}),
            details: { serverId: config.serverId, accountId: config.accountId, progressEvents } };
        }
      }));
      const names = tools.map(t => t.name);
      if (names.some(n => n.length > 64) || new Set(names).size !== names.length) throw new Error('mcp_tool_name_collision');
      extensions.push(defineExtension({ name: `omakase.mcp.${config.serverId}.${config.accountId}`, tools }));
    }
    // Discovery refresh re-lists each server. Tools are registered once at boot
    // from the configured allow-list; a refresh reports what a server now
    // advertises and never registers a tool or widens a server/account scope.
    const refresh = async () => Promise.all(advertised.map(async ({ client, config }) => {
      const names = (await client.listTools()).map(tool => tool.name).sort();
      return { serverId: config.serverId, accountId: config.accountId, advertised: names,
        allowed: names.filter(name => config.tools.includes(name)) };
    }));
    return { extensions, refresh, close: () => Promise.all(clients.map(c => c.close())) };
  } catch (error) { await Promise.all(clients.map(c => c.close())); throw error; }
}
