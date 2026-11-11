module Agents
  # The agent's Concourse tasks still open: the requests it sent that others
  # have yet to settle, and peers' requests it has yet to answer. Read only;
  # the agent settles its own with its concourse_ tools.
  class PeerTasksController < ApplicationController
    include AgentSettings

    def index
      @tasks = @agent.current_peer_tasks.open.includes(:conversation, :concourse_agent).order(created_at: :desc).group_by(&:direction)
    end
  end
end
