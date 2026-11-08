module Agents
  # What the person answered "Always" to (Permission), listed in the agent's
  # settings, where they take one back and the agent asks before the next
  # such call. Only a person's answer in the thread makes one
  # (Invocation#approve!).
  class PermissionsController < ApplicationController
    include AgentSettings

    def index
    end

    def destroy
      @agent.permissions.find(params[:id]).destroy!
      redirect_to agent_permissions_path(@agent), notice: "Removed. #{@agent} will ask first."
    end
  end
end
