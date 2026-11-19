# Mail an agent sends, sent once (#86, docs/email.md "When the mail server
# doesn't answer"). Its Message-ID is chosen and recorded (Dispatch) before
# the message is handed over, so a server that takes it and never answers
# leaves a message that can be looked for: in the Sent folder of the account
# it went through, by that Message-ID alone, and nowhere else. Found, it
# went; not found yet, it is checked in the background; with no Sent folder
# to ask, it stays unknown until a person who checked says on its card
# whether it went (Dispatch#close). A retry meanwhile sends nothing, and
# nothing is ever called "not sent" for being missing from a Sent folder,
# which holds only what its server chose to file there.
#
# The includer sends inside #send_once, raising Unanswered where the server
# may have taken it, and says whether it has a Sent folder to ask
# (#sent_folder?) and what it holds (#find_dispatched).
module Tool::SendsMailOnce
  CHECKING = "Unknown: the mail server took it but didn't answer in time, and it can't be found in your Sent folder yet, so it may have gone. " \
    "Don't send it again: it is being checked, and you'll be told here whether it went. Tell your person it may not have arrived yet."
  UNCONFIRMABLE = "Unknown: the mail server didn't answer in time, and there is no Sent folder this app may read to check, so it may have gone. " \
    "Don't send it again. Tell your person, who can look for it by its Message-ID and say on its card whether it went."

  # The server may have taken the message: it went quiet, or dropped the
  # connection, after the message was on its way.
  class Unanswered < StandardError; end

  private
    # Yields the Message-ID to send under; the block's answer is the call's
    # once it went. `parts` are what make it the same message again.
    def send_once(to:, sender:, domain:, tool_name:, parts:)
      fingerprint = Dispatch.fingerprint(tool_name, sender, *parts)
      refuse_repeated_mail(to, fingerprint)
      message_id = "#{SecureRandom.alphanumeric(24)}@#{domain}"
      dispatch = Dispatch.record(invocation, tool_name: tool_name, sender: sender, fingerprint: fingerprint, provider_id: message_id) or
        return mail_tried(invocation.reload_dispatch, to)
      begin
        answer = yield message_id
      rescue Unanswered
        return unanswered(dispatch, to)
      rescue StandardError
        dispatch.refused
        raise
      end
      dispatch.confirm(message_id)
      answer
    end

    def unanswered(dispatch, to)
      unless sent_folder?(dispatch)
        dispatch.unconfirmable
        return mail_tried(dispatch, to)
      end
      found = begin
        find_dispatched(dispatch)
      rescue Dispatch::LookupFailed
      end
      found ? dispatch.confirm(found) : dispatch.checking!
      mail_tried(dispatch, to)
    end

    # What the call answers for mail it tried, once its server never answered.
    def mail_tried(dispatch, to)
      raise Tool::Refusal, "This email to #{to.to_sentence} was not sent." if dispatch.not_sent?
      return { sent: to, messageId: dispatch.provider_id } if dispatch.sent?
      { unknown: to, messageId: dispatch.provider_id, note: dispatch.unknown? ? UNCONFIRMABLE : CHECKING }
    end

    # The same message again, just sent or perhaps sent: the agent retrying
    # mail that went, or may have, so it isn't sent twice.
    def refuse_repeated_mail(to, fingerprint)
      earlier = agent.dispatches.repeated(fingerprint, by: invocation) or return
      at = Conversation.stamp(earlier.created_at, agent.time_zone)
      id = "Message-ID <#{earlier.provider_id}>"
      raise Tool::Refusal, "This same email went to #{to.to_sentence} at #{at} (#{id}), so it wasn't sent again." if earlier.sent?
      raise Tool::Refusal, "This same email to #{to.to_sentence}, sent at #{at}, may have gone and whether it did is still unknown (#{id}), " \
        "so it wasn't sent again. Ask your person to check #{earlier.where_to_check} and say on its card whether it went." if earlier.unknown?
      raise Tool::Refusal, "This same email to #{to.to_sentence}, sent at #{at}, may have gone and is still being checked (#{id}), " \
        "so it wasn't sent again. You'll be told here whether it went."
    end
end
