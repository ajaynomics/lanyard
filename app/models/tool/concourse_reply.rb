# Answers a task a peer sent this agent, with an explicit state: the end of a
# turn is not the end of the task. Only a task linked to this conversation, and
# always on the network it came on.
class Tool::ConcourseReply < Tool
  prepend Tool::AsksEverySend
  include Tool::ConcourseCalls
  include Tool::ConcourseDestination

  STATES = { "completed" => "TASK_STATE_COMPLETED", "failed" => "TASK_STATE_FAILED", "rejected" => "TASK_STATE_REJECTED",
             "input_required" => "TASK_STATE_INPUT_REQUIRED", "working" => "TASK_STATE_WORKING" }.freeze

  description "Answer a Concourse task a peer sent you. Say where it stands: completed (done, with the answer), failed, rejected (you won't do it), " \
    "input_required (you need something from them; ask in text) or working (a progress note). Nothing tells the peer you are done but this."
  argument :task_id, :string, pattern: "^[A-Za-z0-9_.:-]{1,512}$"
  argument :state, :string, enum: STATES.keys
  argument :text, :string, min_length: 1, max_length: 64_000
  effect :external

  def refusal
    return unless asks_every_send?
    return "The reply needs nonblank text." if arguments["text"].blank?

    task = linked_task(arguments["task_id"], direction: "inbound")
    review_destination(network_of(task), task.peer, task)
    nil
  rescue Refusal => problem
    problem.message
  end

  def call(task_id:, state:, text:)
    peer_task = linked_task(task_id, direction: "inbound")
    channel = network_of(peer_task)
    verify_destination(channel, peer_task.peer, peer_task)
    task = on_concourse { channel.client.reply(task_id, state: STATES.fetch(state), text: text) }
    peer_task.update!(state: task.dig("status", "state"))
    { taskId: task_id, state: peer_task.state }
  end
end
