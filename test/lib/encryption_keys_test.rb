require "test_helper"

# Active Record encryption keys from a secret_key_base, as
# config/initializers/active_record_encryption.rb derives them. A web, job,
# runner or console process eager-loads its models, and so runs that
# initializer, before Rails sets Active Support's key generator digest to
# SHA256 after initialization; a Rake task loads them later. Each is booted
# here as the initializer boots it, with the digest Active Support has then.
class EncryptionKeysTest < ActiveSupport::TestCase
  SECRET = "made-up-secret-key-base-for-encryption-keys-0123456789abcdef".freeze

  test "a process that eager-loads and a Rake task encrypt with the same key, and each reads what the other wrote" do
    web, task = [ OpenSSL::Digest::SHA1, OpenSSL::Digest::SHA256 ].map { booted_keys(SECRET, digest_at_boot: it) }

    assert_equal web.encryption_key.secret, task.encryption_key.secret
    assert_equal "made-up-from-a-task", decrypt(encrypt("made-up-from-a-task", task), web)
    assert_equal "made-up-from-the-web", decrypt(encrypt("made-up-from-the-web", web), task)
  end

  test "it encrypts as web and job processes always have, so stored data is unchanged, and reads what a task wrote before" do
    ours = booted_keys(SECRET, digest_at_boot: OpenSSL::Digest::SHA256)

    assert_equal earlier_key(SECRET, OpenSSL::Digest::SHA1).secret, ours.encryption_key.secret
    { OpenSSL::Digest::SHA1 => "web", OpenSSL::Digest::SHA256 => "task" }.each do |digest, process|
      sealed = encrypt("made-up-#{process}-secret", ActiveRecord::Encryption::KeyProvider.new(earlier_key(SECRET, digest)))
      assert_equal "made-up-#{process}-secret", decrypt(sealed, ours), "a #{process} process sealed it before the fix"
    end
  end

  private
    def encrypt(text, provider) = ActiveRecord::Encryption::Encryptor.new.encrypt(text, key_provider: provider)
    def decrypt(text, provider) = ActiveRecord::Encryption::Encryptor.new.decrypt(text, key_provider: provider)

    # The key a release before the fix sealed with: derived through
    # Rails.application.key_generator, built with whichever digest Active
    # Support had when the process first asked for it.
    def earlier_key(secret_key_base, digest)
      generator = ActiveSupport::KeyGenerator.new(secret_key_base, iterations: 1000, hash_digest_class: digest)
      primary_key, salt = %w[ primary_key salt ].map { generator.generate_key("active_record_encryption/#{it}", 32).unpack1("H*") }
      ActiveRecord::Encryption::Key.new(ActiveSupport::KeyGenerator.new(primary_key, hash_digest_class: OpenSSL::Digest::SHA256).generate_key(salt, 32))
    end

    # The keys a process encrypts with, booted from this secret_key_base by
    # config/initializers/active_record_encryption.rb while Active Support's
    # key generator digest is the one given; this process's are put back.
    def booted_keys(secret_key_base, digest_at_boot:)
      config, generators = ActiveRecord::Encryption.config, Rails.application.instance_variable_get(:@key_generators)
      saved = [ ActiveSupport::KeyGenerator.hash_digest_class, Rails.application.config.secret_key_base, config.primary_key, config.key_derivation_salt, ActiveRecord::Encryption.default_context ]
      ActiveSupport::KeyGenerator.hash_digest_class = digest_at_boot
      Rails.application.config.secret_key_base = secret_key_base
      generators.delete(secret_key_base)
      config.primary_key = nil
      load Rails.root.join("config/initializers/active_record_encryption.rb").to_s
      ActiveRecord::Encryption.key_provider
    ensure
      ActiveSupport::KeyGenerator.hash_digest_class, Rails.application.config.secret_key_base = saved[0], saved[1]
      config.primary_key, config.key_derivation_salt = saved[2], saved[3]
      ActiveRecord::Encryption.default_context = saved[4]
      generators.delete(secret_key_base)
    end
end
