require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/enumerable"
require "json"
require "uri"
require_relative "../../../lib/durable_assistants/passbolt"

# This standalone program receives a generated, loopback-only fixture. Neither
# the fixture nor the runner reads the install's Rails credentials or settings.
fixture = JSON.parse($stdin.read)
Workspace = Data.define(:passbolt_private_key, :passbolt_passphrase)
Agent = Data.define(:passbolt_private_key, :passbolt_passphrase, :workspace)
DurableAssistants.define_singleton_method(:config) do |section, key|
  raise "unexpected setting" unless section == :passbolt
  fixture[key.to_s]
end

refuse = ->(*) { abort "password manager tried to launch a child" }
%i[ capture2 capture2e capture3 popen2 popen2e popen3 ].each { |name| Open3.define_singleton_method(name, refuse) }
%i[ spawn exec fork ].each { |name| Process.define_singleton_method(name, refuse) }
IO.define_singleton_method(:popen, refuse)
%i[ spawn system exec fork ` ].each { |name| Kernel.define_method(name, refuse) }

vault = DurableAssistants::Passbolt
if (library = ENV["PASSBOLT_READER_PROOF_LIBRARY"])
  vault::Native.send(:remove_const, :LIBRARY)
  vault::Native.const_set(:LIBRARY, library.freeze)
end
def refused(vault)
  yield
  raise "the vault request should have been refused"
rescue vault::Error => error
  raise "vault refusal exposed details" unless error.message == "The password manager could not be reached." && error.cause.nil?
end

if ARGV == [ "untrusted" ]
  refused(vault) { vault.sign_ins(nil) }
  exit
end

pid = Process.pid
rows = vault.sign_ins(nil)
want = [
  [ fixture["v5_id"], "Ledger", "https://ledger.example" ],
  [ fixture["id"], "Library", "https://library.example" ],
  [ fixture["shared_id"], "Shared", "https://shared.example" ]
]
raise "list did not preserve metadata" unless rows.map { |row| [ row.id, row.name, row.address ] } == want
raise "list returned a secret" unless rows.all? { |row| row.password.nil? && row.answers.empty? }
found = vault.find_by_name(nil, "library")
raise "lookup was not case-insensitive and exact" unless found.id == fixture["id"]
begin
  vault.find_by_name(nil, "lib")
  raise "lookup accepted a prefix"
rescue vault::Error
end
entry = vault.sign_in(nil, found.id)
raise "read did not decrypt the entry" unless entry.username == "reader" && entry.password == "fixture-password" && entry.account == "fixture-account"
raise "entry inspection exposed a secret" if entry.inspect.include?(entry.password)

workspace = Workspace.new(fixture.fetch("private_key"), fixture["passphrase"])
fixture["private_key"] = "inaccessible-install-key"
refused(vault) { vault.sign_ins(nil) }
agent = Agent.new(nil, nil, workspace)
entry = vault.sign_in(agent, vault.find_by_name(workspace, "LEDGER").id)
raise "read did not decrypt the custom fields" unless entry.address == "https://ledger.example" && entry.answers == [ { "question" => "First library?", "answer" => "fixture-answer" } ]
raise "entry inspection exposed an answer" if entry.inspect.include?("fixture-answer")
shared = vault.sign_in(agent, fixture.fetch("shared_id"))
raise "read did not decrypt shared metadata and password" unless shared.username == "shared-reader" && shared.password == "fixture-shared-password"
refused(vault) { vault.sign_ins(Agent.new("inaccessible-agent-key", "wrong-passphrase", workspace)) }

%w[ denied_url redirect_url ].each do |kind|
  fixture["url"] = fixture.fetch(kind)
  refused(vault) { vault.sign_ins(workspace) }
end
fixture["url"] = fixture.fetch("swapped_url")
refused(vault) { vault.sign_in(workspace, fixture.fetch("id")) }

# The existing Pages reader must retain its different, pinned ABI and policy
# even though the product binding is compiled into the same library.
handle = Fiddle.dlopen(library)
pointer, integer = Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT
release_read = Fiddle::Function.new(handle["ReleaseVaultRead"], [ pointer ] * 8 + [ integer ], integer)
release_output = "\0".b * 257
params = [ fixture["release_origin"], File.binread(ENV.fetch("SSL_CERT_FILE")), fixture["user_id"], fixture["id"],
           fixture["type_id"], workspace.passbolt_private_key, workspace.passbolt_passphrase ]
status = release_read.call(*params, release_output, 257)
raise "existing Pages read changed" unless status.zero? && release_output.split("\0", 2).first == "synthetic_release_read_value"
params[2] = fixture.fetch("shared_id")
status = release_read.call(*params, release_output, 257)
raise "existing Pages read lost its principal pin" unless status == -1 && release_output.bytes.all?(&:zero?)
raise "vault read changed the Ruby process" unless Process.pid == pid
