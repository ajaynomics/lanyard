# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :passphrase, :email, :secret, :token, :code, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  /\Astate\z/, /\Aerror_description\z/,
  "agent_setup.authorization", "agent_setup.instructions",
  /\Aphone_number\z/,
  # A sign-in typed into a form for the vault (SignInLink, Tool::AskForSignIn):
  # its username and account are as private as its password.
  "sign_in.username", "sign_in.account",
  # An OAuth app's client ID, in a sign-in's address too: one read from the
  # vault is never kept or logged (McpServer::VaultClient).
  /\Aclient_id\z/,
  # An OAuth callback's `state` (with its `code`, matched above) would let
  # whoever reads the log finish a connector's sign-in before its browser does.
  :state
]
