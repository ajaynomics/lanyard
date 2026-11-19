require "test_helper"
require "open3"

# An install's processes share one SECRET_KEY_BASE, so they must share its
# encryption keys (config/initializers/active_record_encryption.rb). Each kind
# is booted here as production boots it, in a process of its own: a Rake task,
# which does not eager-load; the web, from config.ru as Falcon loads it (a
# job process boots the same way, through config/environment); and
# bin/rails runner. Each reads what the ones before it wrote, then writes.
class EncryptionKeyProcessesTest < ActiveSupport::TestCase
  PROBE = <<~'RUBY'
    encryptor = ActiveRecord::Encryption.encryptor
    Dir[File.join(ENV.fetch("SEALED"), "*")].sort.each do |path|
      writer = File.basename(path)
      begin
        puts "READ #{writer}=#{encryptor.decrypt(File.read(path))}"
      rescue ActiveRecord::Encryption::Errors::Base => error
        puts "READ #{writer}=#{error.class.name.demodulize}"
      end
    end
    File.write(File.join(ENV.fetch("SEALED"), ENV.fetch("STEP")), encryptor.encrypt("made-up from #{ENV.fetch("STEP")}"))
  RUBY

  test "what a Rake task, the web and bin/rails runner each encrypt, the others decrypt, both ways" do
    Dir.mktmpdir("encryption-key-processes") do |dir|
      probe = File.join(dir, "probe.rb").tap { File.write(it, PROBE) }
      FileUtils.mkdir_p([ File.join(dir, "sealed"), File.join(dir, "rakelib") ])
      File.write(File.join(dir, "rakelib", "probe.rake"), "task(encryption_probe: :environment) { load ENV.fetch(\"PROBE\") }\n")
      kinds = {
        "1-task" => [ "bin/rails", "--rakelibdir", File.join(dir, "rakelib"), "encryption_probe" ],
        "2-web" => [ "-e", 'require "rack"; Rack::Builder.parse_file("config.ru"); load ENV.fetch("PROBE")' ],
        "3-runner" => [ "bin/rails", "runner", probe ],
        "4-task" => [ "bin/rails", "--rakelibdir", File.join(dir, "rakelib"), "encryption_probe" ]
      }

      read = kinds.to_h { |step, command| [ step, boot(dir, step, probe, command) ] }

      assert_equal({ "1-task" => "made-up from 1-task" }, read["2-web"], "the web reads what a Rake task wrote")
      assert_equal({ "1-task" => "made-up from 1-task", "2-web" => "made-up from 2-web" }, read["3-runner"], "runner reads what a Rake task and the web wrote")
      assert_equal({ "1-task" => "made-up from 1-task", "2-web" => "made-up from 2-web", "3-runner" => "made-up from 3-runner" }, read["4-task"],
        "a Rake task reads what the web and runner wrote")
    end
  end

  private
    def boot(dir, step, probe, command)
      database = ->(name) { "sqlite3:#{File.join(dir, "#{name}.sqlite3")}" }
      env = { "RAILS_ENV" => "production", "RAILS_LOG_LEVEL" => "warn", "SECRET_KEY_BASE" => "made-up-secret-key-base-shared-by-every-process-0123456789abcdef",
              "DATABASE_URL" => database.("production"), "CACHE_DATABASE_URL" => database.("cache"), "QUEUE_DATABASE_URL" => database.("queue"),
              "CABLE_DATABASE_URL" => database.("cable"), "APP__URL" => "https://install.example.com", "OIDC__ISSUER" => "https://id.example.com",
              "OIDC__CLIENT_ID" => "made-up-client", "OIDC__CLIENT_SECRET" => "made-up-client-secret",
              "PROBE" => probe, "SEALED" => File.join(dir, "sealed"), "STEP" => step }
      output, error, status = Open3.capture3(env, RbConfig.ruby, *command, chdir: Rails.root)
      assert status.success?, "#{step}: #{error}\n#{output}"
      output.lines.grep(/\AREAD /).to_h { it.delete_prefix("READ ").chomp.split("=", 2) }
    end
end
