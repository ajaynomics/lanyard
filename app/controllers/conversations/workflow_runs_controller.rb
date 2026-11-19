# A person's Cancel for a workflow's run (Workflow::Run#cancel): its helpers
# stop and the steps not started never will. The run is redrawn by broadcast,
# on its line in the thread and in the Helpers panel; one that already ended
# says so.
class Conversations::WorkflowRunsController < ApplicationController
  include RedrawnByBroadcast

  def destroy
    conversation = find_in_workspace(:conversations, params[:conversation_id])
    run = conversation.workflow_runs.find(params[:id])
    redrawn_by_broadcast run.cancel, refusal: "That workflow had already finished.", fallback: conversation
  end
end
