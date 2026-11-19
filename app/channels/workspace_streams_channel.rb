# The live streams of what is in a workspace: its lists, and each agent's and
# thread's (turbo_stream_from ..., channel: WorkspaceStreamsChannel). Only its
# members hear them, as StreamAudience, in front of Turbo's own channel and so
# of this one, asks at every subscription.
class WorkspaceStreamsChannel < Turbo::StreamsChannel
end
