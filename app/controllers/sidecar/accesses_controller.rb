module Sidecar
  # The sidecar asks before it admits or runs anything for a scope, before
  # every tool call and model request too. The answer names exactly the scope
  # asked about; anything else is refused. A paused agent is refused, so a
  # turn under way stops at its next step and spends nothing (Agent::Pausable).
  class AccessesController < PrivateController
    def create
      scope = access
      return render json: { allowed: false, paused: true } if scope.agent.paused?
      render json: { allowed: true, actorId: scope.actor_id, workspaceId: scope.workspace_id, cwd: scope.cwd }
    end
  end
end
