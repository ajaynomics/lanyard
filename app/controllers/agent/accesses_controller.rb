module Agent
  # The sidecar asks before it admits or runs anything for a scope. The answer
  # names exactly the scope asked about; anything else is refused.
  class AccessesController < PrivateController
    def create
      scope = access
      render json: { allowed: true, actorId: scope.actor_id, workspaceId: scope.workspace_id, cwd: scope.cwd }
    end
  end
end
