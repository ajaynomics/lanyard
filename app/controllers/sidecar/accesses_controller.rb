module Sidecar
  # The sidecar asks before it admits or runs anything for a scope, before
  # every tool call and model request too. The answer names exactly the scope
  # asked about; anything else is refused. A paused agent is refused, so a
  # turn under way stops at its next step and spends nothing (Agent::Pausable).
  class AccessesController < PrivateController
    def create
      scope = access
      return render json: { allowed: false, paused: true } if scope.agent.paused?
      permission = { allowed: true, actorId: scope.actor_id, workspaceId: scope.workspace_id, cwd: scope.cwd }
      computer = scope.agent.computer
      if params[:configuredSsh] == true && computer&.configured_ssh? && !computer.held? && (target = computer.descriptor)
        permission[:configuredSsh] = target.slice(:host, :user, :folder, :keyring)
      end
      # Either kind of SSH computer keeps its Sprite for the screen (Computer#retains_browser?).
      if params[:retainedBrowser] == true && conversation.retained_browser?
        permission[:retainedBrowser] = { prefix: scope.agent.computer.name, conversationId: conversation.durable_id }
      end
      if params[:sandboxBrowser] == true && (name = scope.agent.sandbox_drive_browser)
        permission[:sandboxBrowser] = { name: name, conversationId: conversation.durable_id,
                                         ssh: computer.descriptor.slice(:host, :user, :folder, :keyring) }
      end
      render json: permission
    end
  end
end
