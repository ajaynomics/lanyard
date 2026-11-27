import { COMPUTER_NAME } from './named-computers.mjs';

const smallest = Object.freeze({ vcpus: 1, memoryMib: 4096, autoHibernateSeconds: 900 });

// The transport must reconcile the one stable identity and never retry
// uncertain creation. No production transport is wired in this source slice.
export function boxdComputer({ admission, client } = {}) {
  const { enabled, machine, actorId, workspaceId } = admission ?? {};
  const configured = enabled === true && typeof machine === 'string' && COMPUTER_NAME.test(machine) &&
    typeof actorId === 'string' && actorId.length > 0 &&
    typeof workspaceId === 'string' && workspaceId.length > 0 && typeof client?.ensure === 'function';
  let opening;
  const admits = (computer, scope) => configured && scope?.actorId === actorId && scope?.workspaceId === workspaceId &&
    computer?.provider === 'boxd' && computer.name === machine && !computer.held;
  return Object.freeze({
    configured, admits,
    async env(computer, scope) {
      if (!admits(computer, scope)) throw new Error('boxd_unavailable');
      opening ??= Promise.resolve().then(() => client.ensure({ name: machine, ...smallest }));
      return opening;
    }
  });
}
