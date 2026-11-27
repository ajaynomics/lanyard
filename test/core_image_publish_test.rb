require "digest"
require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "stringio"
require "tmpdir"
require "yaml"
require "zlib"

class CoreImagePublishTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  APP = "registry.example.com/example/core:revision"
  COMPUTER = "registry.example.com/example/core-agent:revision"
  HOLD_PROOF = "registry.example.com/example/core-agent-hold-proof:revision"

  def test_different_revisions_do_not_share_a_publish_concurrency_group
    assert_equal "${{ github.repository }}-publish-${{ github.sha }}", publish_job.dig("concurrency", "group")
  end

  def test_publish_checks_out_the_tested_revision
    assert_equal "ci", publish_job.fetch("needs")
    checkout = publish_job.fetch("steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
    assert_equal "${{ github.sha }}", checkout.dig("with", "ref")
  end

  def test_a_marker_in_a_deleted_layer_of_an_everyday_image_blocks_all_pushes
    [ APP, COMPUTER ].each do |image|
      marker = "opt/bridge-components-pro/LICENSE"
      calls, output, status = publish(image => {
        layers: [ tar(marker => "Synthetic licence"), tar("opt/.wh..wh..opq" => "") ]
      })

      assert_empty calls.grep(/\Apush /), "#{image}: publisher reached push"
      assert_includes calls, "save #{image}"
      refute_includes calls, "login"
      refute status.success?
      assert_includes output, "Pro component or licence marker"
      refute_includes output, marker
    end
  end

  def test_all_clean_images_are_checked_before_their_push
    files = { "rails/.env.example" => "", "rails/config/deploy.example.yml" => "",
      "rails/config/agents/assistant/agent.yml" => "", "opt/.wh..wh..opq" => "" }
    calls, output, status = publish(APP => { layers: [ tar(files) ] })

    assert status.success?, output
    assert_equal [ "save #{APP}", "save #{COMPUTER}", "login", "push #{APP}", "push #{COMPUTER}", "save #{HOLD_PROOF}", "push #{HOLD_PROOF}" ], calls
  end

  # The hold proof never stands between main and its everyday images.
  def test_a_marker_in_the_hold_proof_image_leaves_only_it_unpublished
    calls, output, status = publish(HOLD_PROOF => { layers: [ tar("opt/example/LICENSE" => "Bridge Components Pro") ] })

    assert_equal [ "save #{APP}", "save #{COMPUTER}", "login", "push #{APP}", "push #{COMPUTER}", "save #{HOLD_PROOF}" ], calls
    refute status.success?
    assert_includes output, "Pro component or licence marker"
  end

  def test_a_failed_or_refused_hold_proof_check_leaves_only_it_unpublished
    calls, _output, status = publish({}, "echo 'docker: Error response from daemon: refused' >&2; exit 125")

    assert_equal [ "save #{APP}", "save #{COMPUTER}", "login", "push #{APP}", "push #{COMPUTER}" ], calls
    refute status.success?
  end

  def test_only_the_hold_proof_test_container_gets_extra_docker_options
    steps = publish_steps
    hold = steps.index { it.include?("bin/check-hold-proof") }
    push = steps.index { it.include?("docker push \"$ORIGIN-agent:") }
    assert hold > push, "the hold proof runs before the everyday images are pushed"
    steps.each { refute_match(/--cap-add|seccomp/, it) }

    script = File.read(File.join(ROOT, "bin/check-hold-proof"))
    granted = script.lines.grep(/--cap-add/)
    assert_equal 1, granted.size
    assert_match(/\Acontainer=\$\(docker create --pull never --network none --cap-add NET_ADMIN --security-opt seccomp=unconfined /, granted.first)
    refute_match(/--cap-add|--privileged/, script.lines.grep(/docker build/).join)
  end

  def test_an_unreadable_layer_blocks_all_pushes
    incomplete = tar("opt/sample" => "synthetic").byteslice(0, 1024)
    calls, output, status = publish(COMPUTER => { layers: [ incomplete ] })

    assert_empty calls.grep(/\Apush /)
    refute status.success?
    assert_includes output, "could not read Docker image archive"
  end

  def test_generic_file_markers_are_refused_without_echoing_paths
    { "opt/example/LICENSE" => [ "Bridge Components Pro", "Pro component or licence marker" ],
      "opt/example/COPYING" => [ "Pro licence", "Pro component or licence marker" ],
      "rails/config/master.key" => [ "made-up", "credential or secret indicator" ],
      "rails/config/agents/templates.yml" => [ "made-up", "install configuration path" ],
      "rails/config/deploy.production.yml" => [ "made-up", "install configuration path" ] }.each do |path, (contents, message)|
      calls, output, status = publish(COMPUTER => { layers: [ tar(path => contents) ] })

      assert_empty calls.grep(/\Apush /)
      refute status.success?
      assert_includes output, message
      refute_includes output, path
    end
  end

  def test_a_credential_assignment_in_image_history_is_not_printed
    canary = "made-up-value-for-this-test"
    calls, output, status = publish(COMPUTER => {
      history: [ { "created_by" => "ENV EXAMPLE_TOKEN=#{canary}" } ]
    })

    assert_empty calls.grep(/\Apush /)
    refute status.success?
    assert_includes output, "credential or secret indicator"
    refute_includes output, canary
  end

  # The publish job runs in a container but drives the host's Docker, which
  # cannot see the job's own temporary folders: a bind mount of one fails.
  def test_the_hold_proof_check_mounts_nothing_from_the_job
    script = File.read(File.join(ROOT, "bin/check-hold-proof"))
    docker = script.gsub("\\\n", " ").lines.grep(/\bdocker (run|create)\b/).join

    refute_match(/--mount|--volume|\s-v\s/, docker)
    assert_match(/\bdocker cp "\$work\/\." "\$container:\/proof"/, script)
  end

  private
    def publish(images = {}, hold_proof_check = "exit 0")
      Dir.mktmpdir("core-publish") do |dir|
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p(bin)
        %w[ check-pdf-reader check-computer-image ].each do |name|
          File.write(File.join(bin, name), "#!/bin/sh\nexit 0\n", perm: 0o755)
        end
        File.write(File.join(bin, "check-hold-proof"), "#!/bin/sh\n#{hold_proof_check}\n", perm: 0o755)
        check = File.join(ROOT, "bin/check-core-images")
        FileUtils.cp(check, bin) if File.file?(check)
        File.write(File.join(bin, "docker"), <<~SH, perm: 0o755)
          #!/bin/sh
          set -eu
          case "$1" in
            build|tag) ;;
            save)
              printf 'save %s\n' "$2" >> calls
              case "$2" in
                '#{APP}') cat app.tar ;;
                '#{COMPUTER}') cat computer.tar ;;
                '#{HOLD_PROOF}') cat hold-proof.tar ;;
                *) exit 64 ;;
              esac ;;
            login) cat > /dev/null; echo login >> calls ;; # reads the token, as docker login does
            push) printf 'push %s\n' "$2" >> calls ;;
            *) exit 64 ;;
          esac
        SH
        File.binwrite(File.join(dir, "app.tar"), docker_save(APP, **images.fetch(APP, {})))
        File.binwrite(File.join(dir, "computer.tar"), docker_save(COMPUTER, **images.fetch(COMPUTER, {})))
        File.binwrite(File.join(dir, "hold-proof.tar"), docker_save(HOLD_PROOF, **images.fetch(HOLD_PROOF, {})))
        output = +""
        status = nil
        # Run the publisher's actual commands in step order, but never contact Docker or a registry.
        publish_steps.each do |script|
          out, err, status = Open3.capture3({
            "PATH" => "#{bin}:/usr/bin:/bin", "REGISTRY" => "registry.example.com",
            "REGISTRY_PUSH_TOKEN" => "x" * 100_000 # more than a pipe holds, so a stub that never reads it breaks the Login step every time
          }, "bash", "-e", "-o", "pipefail", "-c", script, chdir: dir, unsetenv_others: true)
          output << out << err
          break unless status.success?
        end
        calls = File.exist?(File.join(dir, "calls")) ? File.readlines(File.join(dir, "calls"), chomp: true) : []
        [ calls, output, status ]
      end
    end

    def publish_job
      YAML.safe_load_file(File.join(ROOT, ".github/workflows/ci.yml")).fetch("jobs").fetch("publish")
    end

    def publish_steps
      publish_job.fetch("steps").filter_map do |step|
        next if step["if"] == "always()"
        step["run"]&.gsub(/\$\{\{ github\.(\w+) \}\}/) do
          { "repository" => "example/core", "repository_owner" => "example", "sha" => "revision" }.fetch($1)
        end
      end
    end

    def docker_save(tag, layers: [ tar("opt/sample" => "synthetic") ], history: [])
      files = layers.to_h do |layer|
        if tag == APP
          [ "#{Digest::SHA256.hexdigest(layer)}/layer.tar", layer ]
        else
          blob = Zlib.gzip(layer)
          [ "blobs/sha256/#{Digest::SHA256.hexdigest(blob)}", blob ]
        end
      end
      manifest = [ { "RepoTags" => [ tag ], "Config" => "config.json", "Layers" => files.keys } ]
      config = {
        "config" => { "Env" => [ "PATH=/usr/bin:/bin" ] }, "history" => history,
        "rootfs" => { "diff_ids" => layers.map { |layer| "sha256:#{Digest::SHA256.hexdigest(layer)}" } }
      }
      tar(files.merge("manifest.json" => JSON.generate(manifest), "config.json" => JSON.generate(config)))
    end

    def tar(files)
      StringIO.new("".b).tap do |io|
        Gem::Package::TarWriter.new(io) do |archive|
          files.each do |name, bytes|
            archive.add_file_simple(name, 0o644, bytes.bytesize) { |entry| entry.write(bytes) }
          end
        end
      end.string
    end
end
