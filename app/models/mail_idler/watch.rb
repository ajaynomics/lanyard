# One box watched (MailIdler): a thread of its own holding a connection open,
# asking the server to say the moment a message lands (IMAP IDLE), and
# enqueuing that box's own fetch when it does.
#
# IDLE is asked for again well before the half hour RFC 2177 allows, so no
# server drops a watcher that outstayed its welcome. A connection dropped,
# refused or never made is tried again, waiting longer each time, so a server
# that is down is not hammered; and the box is read on every fresh
# connection, since a message may have landed while nobody was watching.
class MailIdler::Watch
  IDLE_FOR = 25.minutes # under RFC 2177's 29 minutes, and under what servers allow
  BACKOFF = 5.seconds # after a connection failed, doubling
  LONGEST_BACKOFF = 5.minutes
  STOP_WITHIN = 2 # seconds to wait for the thread to let go of its connection

  # What a server, the vault or the network may raise while a box is watched.
  # Said in our words, never the server's own, which could echo what it was sent.
  EXPECTED = [ Agent::MailAccount::SignInError, Workspace::MailDomain::SharedMailbox, ActiveRecord::RecordNotFound,
    *Agent::MailAccount::Inbox::REFUSED, *Agent::MailAccount::Inbox::UNREACHABLE ].freeze

  def initialize(box, idle_for: IDLE_FOR, backoff: BACKOFF)
    @box, @idle_for, @backoff = box, idle_for, backoff
    @stopped = Concurrent::Event.new
  end

  # Starts the thread, or starts it again where it has stopped: a watcher
  # whose thread is gone is a box left to the minute's read.
  def start
    return if @stopped.set? || @thread&.alive?
    @thread = Thread.new { watch }
  end

  def stop
    @stopped.set
    disconnect # the thread is waiting on the server, and wakes refused
    @thread&.join(STOP_WITHIN)
  end

  private
    def watch
      wait = @backoff
      until @stopped.set?
        begin
          hold
          wait = @backoff
        rescue *EXPECTED => problem
          Rails.logger.warn("Mail idler: #{@box.key} is not watched (#{problem.class.name})")
        rescue StandardError => problem
          Rails.logger.error("Mail idler: #{@box.key} stopped being watched (#{problem.class.name})")
        end
        @stopped.wait(wait)
        wait = [ wait * 2, LONGEST_BACKOFF ].min
      end
    end

    # One connection, held open until it drops or the idler stops.
    def hold
      @imap = Rails.application.executor.wrap { DurableAssistants::Email.listen(@box.mailbox) }
      # A server with nothing to offer is left to the minute's read: asking it
      # again every few seconds would be a poll of a worse kind.
      return @stopped.wait(LONGEST_BACKOFF) unless @imap
      wake # a message may have landed while nobody was watching
      until @stopped.set?
        wake if DurableAssistants::Email.idle(@imap, @idle_for)
      end
    ensure
      disconnect
    end

    # The box's own fetch, which reads it as it has always been read: one read
    # of a box at a time, and nothing taken twice.
    def wake = Rails.application.executor.wrap { @box.wake }

    def disconnect
      @imap&.disconnect
    rescue StandardError
      nil
    ensure
      @imap = nil
    end
end
