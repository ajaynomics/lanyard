const identity = call => JSON.stringify([call.actorId, call.workspaceId, String(call.conversationId),
  String(call.taskId), call.callId, call.digest]);

// Durable's history proves a call existed, not that it is still executing.
// Only the forwarder can register a live call. A stopped or restarted process
// cannot attest to one that is no longer in its executor.
export function liveInvocations() {
  const active = new Map();
  return {
    enter(call, signal, { helper, env }) {
      if (helper || !signal || (call.tool !== 'forge' && !(call.tool === 'use_tool' && call.arguments?.name === 'forge'))) return;
      const key = identity(call);
      const proof = { signal, env };
      active.set(key, proof);
      return () => { if (active.get(key) === proof) active.delete(key); };
    },
    get(call) {
      const proof = active.get(identity(call));
      if (proof?.signal.aborted === false) return proof;
    },
    includes(call) { return Boolean(this.get(call)); },
  };
}
