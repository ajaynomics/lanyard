# Run with bin/rails test test/proofs/forge_files.rb after installing agent's
# locked npm packages. The regular suites test both ends independently.
require_relative "../test_helper"
require_relative "../test_helpers/agent_test_helper"
require "capybara"
require "rackup/handler/falcon"
require "open3"

Capybara.register_server(:forge_proof) do |app, port, host|
  Rackup::Handler::Falcon.run(app, Host: host, Port: port)
end
Capybara.server = :forge_proof

class ForgeFilesProof < ActiveSupport::TestCase
  include AgentTestHelper

  test "two 50 MiB files cross the real Falcon and sidecar callbacks through a remote guest pipe" do
    sizes = Hash.new(0)
    server = Capybara::Server.new(observed_rack(sizes), host: "127.0.0.1").boot
    install_sidecar_settings
    user = create_user
    agent = user.agents.sole
    bytes = 50.megabytes
    push_sha = digest_of("M")
    stage_sha = digest_of("Q")
    scope = { actorId: user.id.to_s, workspaceId: agent.id.to_s }

    with_setting(:access, :emails, [ user.email ]) do
      with_setting(:pi_durable, :forge_files, { agent_id: agent.id, workspace_id: agent.workspace_id }) do
        Dir.mktmpdir("forge-proof-") do |home|
          Open3.popen2("node", Rails.root.join("agent/test/forge-file-peer.mjs").to_s) do |input, output, child|
            input.puts({ railsUrl: server.base_url, railsToken: RAILS_TOKEN, sidecarToken: SIDECAR_TOKEN, home: home, scope: scope, sha256: push_sha }.to_json)
            info = answer(output)
            with_setting(:pi_durable, :sidecar_url, "http://127.0.0.1:#{Integer(info.fetch('port'))}") do
              conversation = create_conversation(agent, durable_id: info.fetch("id").to_s)
              invocation = conversation.invocations.create!(task_id: "7", call_id: "synthetic-forge", tool_name: "forge",
                arguments: {}, digest: "d" * 64, state: :running, started_at: Time.current)
              seam = ForgeFiles.new(invocation)
              File.open(File.join(home, "source"), "w+b", 0o600) do |source|
                chunk = "Q" * 1.megabyte
                50.times { source.write(chunk) }
                source.rewind
                elapsed = measure(child.pid) { assert_equal stage_sha, seam.stage(io: source, bytes: bytes, sha256: stage_sha).sha256 }
                input.puts({ check: stage_sha }.to_json)
                download = answer(output)
                assert_equal bytes + 1, download.fetch("sent")
                assert_equal 1.megabyte, download.fetch("largestSent")
                assert_equal ForgeFiles::CHUNK_BYTES, sizes[:download]
                puts "Falcon download #{bytes} bytes; #{elapsed.to_json}; Rack chunk #{sizes[:download]}; guest #{download.to_json}"
              end
              elapsed = measure(child.pid) do
                seam.take(bytes: bytes, sha256: push_sha) do |file|
                  hash = Digest::SHA256.new
                  total = 0
                  while (chunk = file.read(ForgeFiles::CHUNK_BYTES))
                    total += chunk.bytesize
                    hash.update(chunk)
                  end
                  assert_equal bytes, total
                  assert_equal push_sha, hash.hexdigest
                end
              end
              input.puts("{}")
              upload = answer(output)
              assert_equal bytes + 52, upload.fetch("received")
              assert_operator upload.fetch("largestReceived"), :<=, 1.megabyte
              assert_equal ForgeFiles::CHUNK_BYTES, sizes[:upload]
              puts "Falcon upload #{bytes} bytes; #{elapsed.to_json}; Rack read #{sizes[:upload]}; cumulative guest #{upload.to_json}"
            end
            input.close
            assert Timeout.timeout(10) { child.value.success? }
          ensure
            Process.kill("TERM", child.pid) if child&.alive?
          end
        end
      end
    end
  ensure
    remove_sidecar_settings
  end

  MeasuredBody = Struct.new(:body, :sizes) do
    def each
      body.each do |chunk|
        sizes[:download] = [ sizes[:download], chunk.bytesize ].max
        yield chunk
      end
    end

    def close = body.close
  end

  private
    def observed_rack(sizes)
      lambda do |env|
        mode = env["HTTP_X_FORGE_MODE"]
        if mode == "push"
          input = env.fetch("rack.input")
          input.define_singleton_method(:read) do |length = nil, *args|
            raise "unbounded read of forge upload" unless length&.between?(1, ForgeFiles::CHUNK_BYTES)

            sizes[:upload] = [ sizes[:upload], length ].max
            super(length, *args)
          end
        end
        code, headers, body = Rails.application.call(env)
        [ code, headers, mode == "stage" && code == 200 ? MeasuredBody.new(body, sizes) : body ]
      end
    end

    def answer(output) = Timeout.timeout(15) { JSON.parse(output.gets || raise("sidecar proof exited")) }

    def digest_of(byte)
      hash = Digest::SHA256.new
      chunk = byte * 1.megabyte
      50.times { hash.update(chunk) }
      hash.hexdigest
    end

    def measure(sidecar_pid)
      pids = [ Process.pid, sidecar_pid ]
      baseline = pids.map { rss_kib(it) }
      peak = baseline.dup
      sample = -> { pids.each_with_index { |pid, i| peak[i] = [ peak[i], rss_kib(pid) ].max } }
      sampler = Thread.new { loop { sample.call; sleep 0.005 } }
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      sample.call
      { seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(3),
        rails_peak_kib: peak[0], rails_growth_kib: peak[0] - baseline[0],
        sidecar_peak_kib: peak[1], sidecar_growth_kib: peak[1] - baseline[1] }
    ensure
      sampler&.kill&.join
    end

    def rss_kib(pid) = File.read("/proc/#{pid}/status")[/^VmRSS:\s+(\d+)/, 1].to_i
end
