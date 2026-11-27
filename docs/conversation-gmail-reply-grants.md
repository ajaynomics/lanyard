# Gmail reply grants for one conversation

From an agent's **Tools**, open its **own connectors**. On that page, the
workspace owner can allow one address for each of the conversation's Gmail
connectors. The page names the agent; there is no agent picker. A connector
must be signed in to add a grant. If it is off, it cannot use the grant
until it is turned on. **Revoke** removes a grant.

A grant only waives the send card for a reply in an existing Gmail thread
on that connector, from that exact conversation and agent. Gmail must
confirm that the granted address is already in the thread. It must be the
only recipient across To, Cc and Bcc, and appear in To or Cc. New mail,
drafts, extra recipients, or a reply the app cannot verify still follow
their usual approval rules. No search access is granted.

The conversation records the address for each use of the grant. Removing
the connector, signing out, replacing the Google sign-in, moving the agent,
or transferring workspace ownership clears the grant. Routine token renewal
does not. A revoke takes effect for any reply not yet recorded for dispatch.
Workspace-wide Gmail grants are unchanged; see
[Connectors](connectors.md#gmail-replies-without-asking).
