// pi-durable's tool_search, for an agent with lookup tools (agentExtension):
// the model searches them and calls those it finds as its own, typed, through
// Rails. `limit` is the sidecar's capacity minus its own tools, including
// tool_search. Rails starts below that capacity to leave room to load tools.
// The search loads no more than the space still available;
// the rest stay where a code mode script reaches them. Nothing is refused.
import { defineTool } from '@earendil-works/pi-durable';
import { createToolSearchTool } from '@earendil-works/pi-durable/tool-search';

export function toolSearch(definition, limit) {
  const search = createToolSearchTool();
  const lookup = new Map(definition.lookup.map(tool => [tool.name, tool]));
  return defineTool({ ...search, async execute(args, api, context) {
    const found = await search.execute(args, api, context);
    const names = found.details.loaded;
    const loaded = (await api.agent(context)).tools.filter(tool => lookup.has(tool.name)).length;
    const room = Math.max(limit - definition.tools.length - loaded, 0);
    if (names.length <= room) return found;
    const kept = names.slice(0, room);
    const line = name => `- ${name}: ${(lookup.get(name)?.description ?? '').trim().split(/\r?\n/)[0]}`;
    const script = definition.capabilities?.includes('codemode') ? '; call them from a codemode script as tools.<name>(...)' : '';
    const text = [kept.length > 0 && `Loaded ${kept.length}. They are available from your next call:\n${kept.map(line).join('\n')}`,
      `Not loaded, as you have no room for more tools${script}:\n${names.slice(room).map(line).join('\n')}`];
    return { output: [{ type: 'text', text: text.filter(Boolean).join('\n') }], details: { loaded: kept },
      ...(kept.length > 0 ? { control: { addTools: kept } } : {}) };
  } });
}
