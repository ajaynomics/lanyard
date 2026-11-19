# An outside contact as the app compares them: an email address, lower case,
# or a North American number as its ten digits, as voip.ms gives and takes it.
# Anything else (a Concourse handle, a Telegram chat) is no contact.
module Workspace::Contact
  EMAIL = URI::MailTo::EMAIL_REGEXP
  PHONE = /\A\+?[\d\s().-]{10,}\z/

  def self.normalize(value)
    value = value.to_s.strip
    if value.match?(EMAIL) then value.downcase
    elsif value.match?(PHONE) then value.gsub(/\D/, "").sub(/\A1(?=\d{10}\z)/, "").then { it if it.match?(Agent::PHONE_NUMBER) }
    end
  end

  # Its normal forms, those that are contacts.
  def self.all(values) = Array(values).filter_map { normalize(it) }.uniq

  # As people write it: an address as it is, a number (416) 555-0199.
  def self.label(contact) = contact.to_s.match?(/\A\d{10}\z/) ? "(#{contact[0, 3]}) #{contact[3, 3]}-#{contact[6, 4]}" : contact.to_s
end
