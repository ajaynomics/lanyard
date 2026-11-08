module Agents
  module Computers
    # An SSH computer's machine (docs/computers.md): the sidecar's public key,
    # for the machine's authorized_keys, and the machine's host key, which the
    # person trusts once, comparing its fingerprint with one they got another
    # way. A key that changed is never trusted from here.
    class HostKeysController < ApplicationController
      include AgentSettings
      before_action :set_computer

      # Asked of the sidecar while the page waits in a frame: reaching a
      # machine may take seconds.
      def show
        client = DurableAssistants::PiDurable::Client.new
        @public_key = client.ssh_key["publicKey"]
        @host_key = client.ssh_host(host: @computer.ssh_host, user: @computer.ssh_user)
      rescue DurableAssistants::PiDurable::Client::Error
        @unreachable = true
      end

      def create
        DurableAssistants::PiDurable::Client.new.trust_ssh_host(host: @computer.ssh_host, user: @computer.ssh_user,
          fingerprints: Array(params[:fingerprints]))
        redirect_to agent_computer_path(@agent), notice: "Trusted #{@computer.ssh_host}.", status: :see_other
      rescue DurableAssistants::PiDurable::Client::Error => error
        redirect_to agent_computer_path(@agent), status: :see_other, alert: error.status == 409 ?
          "#{@computer.ssh_host}'s key is not the one you saw. Nothing was trusted; check it with whoever runs the machine." :
          "#{@computer.ssh_host} could not be reached. Nothing was trusted."
      end

      private
        def set_computer
          @computer = @agent.computer
          raise ActiveRecord::RecordNotFound unless @computer&.ssh? && @computer.valid?
        end
    end
  end
end
