import { defineExtension, wrapTool } from '@earendil-works/pi-durable';

export const FILE_TOOLS = Object.freeze(['read', 'write', 'edit', 'bash']);
export const COMPUTER_NAME = /^[a-z0-9][a-z0-9-]{0,49}$/;

// Omission is the only way to ask for the usual computer. A spelling error
// must not send a command, or a file write, to a different machine.
export function chooseComputer(usual, named, name) {
  if (name === undefined) return usual;
  if (typeof name !== 'string' || !named || !Object.hasOwn(named, name)) throw new Error('unknown_computer');
  return named[name];
}

export function validNamedComputers(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const entries = Object.entries(value);
  if (entries.length !== 1) return false;
  const [[alias, computer]] = entries;
  return COMPUTER_NAME.test(alias) && alias !== 'constructor' && alias !== 'prototype' &&
    computer && typeof computer === 'object' && !Array.isArray(computer) &&
    Object.keys(computer).filter(key => key !== 'held').sort().join(',') === 'name,provider' &&
    computer.provider === 'boxd' && typeof computer.name === 'string' && COMPUTER_NAME.test(computer.name) &&
    (computer.held === undefined || computer.held === true);
}

export function namedCodingTools(envOf) {
  return defineExtension({ name: 'omakase.named-computers', wraps: FILE_TOOLS.map(name => wrapTool({ name }, tool => ({
    ...tool,
    parameters: { ...tool.parameters, properties: { ...tool.parameters.properties,
      computer: { type: 'string', description: 'Exact name of the optional computer. Omit to use the usual computer.' } } },
    async execute(args, api, context) {
      const { computer, ...original } = args;
      if (computer === undefined) return tool.execute(args, api, context);
      const env = await envOf(api, computer, context);
      return tool.execute(original, { ...api, env }, context);
    }
  }))) });
}
