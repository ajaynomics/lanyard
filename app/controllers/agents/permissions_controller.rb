module Agents
  # The person takes back an "Always" (Permission) on the agent's page; the
  # agent asks before the next such call. Only a person's answer in the thread
  # makes one (Invocation#approve!).
  class PermissionsController < ApplicationController
    def destroy
      agent = Current.user.agents.find(params[:agent_id])
      agent.permissions.find(params[:id]).destroy!
      redirect_to agent, notice: "Removed. #{agent} will ask first."
    end
  end
end
