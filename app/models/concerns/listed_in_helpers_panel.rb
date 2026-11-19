# A helper or a workflow's run, listed in the Helpers panels (helpers/_panel):
# when it changes, its agent's panel and its workspace's are redrawn and morphed
# in place. A stream, not a page refresh: Turbo drops a refresh that arrives
# while the page is still fetching the one before, so a report or a step
# moments after another could leave the panel behind; a stream is applied
# every time, in order, and the panel shows the last one sent.
module ListedInHelpersPanel
  extend ActiveSupport::Concern

  private
    def redraw_helpers_panels
      agent, workspace = conversation.agent, conversation.workspace
      redraw_helpers_panel agent, helpers: agent.helpers.own, runs: agent.workflow_runs, agent: agent
      redraw_helpers_panel workspace, helpers: workspace.helpers.own, runs: workspace.workflow_runs
    end

    def redraw_helpers_panel(owner, **locals)
      Turbo::StreamsChannel.broadcast_replace_to owner, :helpers, target: "helpers_panel", partial: "helpers/panel", locals: locals, attributes: { method: :morph }
    end
end
