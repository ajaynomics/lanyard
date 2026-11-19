# Mail and texts reach an agent in seconds rather than at the next minute's
# read (#262, docs/email.md, "How soon it arrives"): one connection held open
# on every box the install reads, each asking its server to say the moment a
# message lands (IMAP IDLE, RFC 2177) and enqueuing that box's own fetch when
# it does.
#
# It lives in the job role's mail worker (config/queue.yml), started and
# stopped with it (config/initializers/solid_queue.rb). That worker is one
# process, so an install has exactly one idler, and no new role to deploy. A
# worker that dies is started again by Solid Queue's supervisor, and the
# idler with it.
#
# Nothing here reads a message: a watcher only enqueues the existing fetch
# (CatchAllFetchJob, MailAccountFetchJob, WorkspaceMailFetchJob), so one box
# is still read one read at a time, by the code that has always read it.
# EmailFetchJob's minute is the net underneath: a server that does not offer
# IDLE, a connection dropped without a word, or a watcher that stopped leaves
# a box no more than a minute behind, as every box was before this.
class MailIdler
  # The worker whose process holds the connections, and the queue its fetches
  # wait on, where the minute's sweeps are not ahead of them.
  QUEUE = "mail".freeze

  # How soon a box added or taken away is picked up.
  REFRESH = 30.seconds

  class << self
    # One idler to a process: starting a second stops the first.
    def start(**settings)
      stop
      @idler = new(**settings)
      @thread = Thread.new { @idler.run }
      @idler
    end

    def stop
      @idler&.stop
      @thread&.join(STOP_WITHIN)
      @idler, @thread = nil, nil
    end

    def running? = @idler.present?
  end

  STOP_WITHIN = 5 # seconds to wait for the watchers to let go, at a deploy

  def initialize(refresh: REFRESH, **watching)
    @refresh, @watching = refresh, watching
    @watches, @stopped = {}, Concurrent::Event.new
  end

  # Keeps a watcher on every box, until it is stopped: one added is watched
  # within REFRESH, one taken away is let go, and one whose thread is gone is
  # started again.
  def run
    until @stopped.set?
      begin
        refresh
      rescue StandardError => problem
        # A database that cannot be read now must not end the idler: the next
        # pass tries again, and the minute's read covers the boxes meanwhile.
        Rails.logger.warn("Mail idler: the boxes could not be read (#{problem.class.name})")
      end
      @stopped.wait(@refresh)
    end
  ensure
    let_go
  end

  def stop
    @stopped.set
    let_go
  end

  # The boxes watched now, by key, for the tests and the log.
  def watching = @watches.keys.sort

  private
    def refresh
      boxes = Rails.application.executor.wrap { MailIdler::Box.watched }.index_by(&:key)
      (@watches.keys - boxes.keys).each { let_go_of(it) }
      boxes.each { |key, box| (@watches[key] ||= MailIdler::Watch.new(box, **@watching)).start }
    end

    def let_go = @watches.keys.each { let_go_of(it) }

    def let_go_of(key) = @watches.delete(key)&.stop
end
