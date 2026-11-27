# Reporting tree

The Agents page uses the same workspace tree in **List** and **Chart**.
Chart is available on wide browser screens. Phones and the iOS app show
the indented List, even when the browser remembers Chart or opens its link.
That does not change the remembered desktop view. The button to the left of
an agent opens its direct reports and shows how many there are. Click the
agent to open its thread. Working, unread and waiting status update live;
unread stands in place of working dots when both apply.

Branches start open. When you close one, this browser remembers it across
reloads and in both views. A closed branch still shows how many cards wait
below it. The sidebar opens the path to the current thread without changing
your preference. Search and the **Sort and filter** menu work in both views.
Sort orders siblings, not the whole tree. Search and filters show only
matches. Reports stay below their listed manager; when a manager isn't
listed, its report keeps its depth in List and names the manager.

## Change a manager

A workspace owner opens the agent's **⋯** menu and chooses
**Move in reporting tree…**. Pick a manager under **Reports to**, or choose
**No manager** for the top level. The picker previews where the agent will
go and how many direct reports will follow. Choose **Move agent** to save.
Use Tab and Enter to open the picker, arrow keys to select a manager, and
Escape to cancel. There is no drag-and-drop.

The tree has at most three levels within one workspace. Moving an agent
moves its whole branch. If a choice becomes invalid before saving, pick
again. You cannot choose an archived agent as a new manager.

Deleting an agent or moving it to another workspace promotes its direct
reports to its old manager, or the top level if it had none. Their branches
stay with them. Only the named agent changes workspaces and it arrives at
the top level. Archiving keeps reporting lines; an archived manager remains
visible above active reports.

## What reporting does not change

A reporting line gives no access to another agent's thread, tools, files or
credentials. It gives no approval or permission, sends no message, and
does not change who answers an existing task or card. On its next turn, an
agent is told its direct manager and direct reports. For new reporting
messages, it uses the workspace's home Concourse network if both can speak
there, or a single shared connected network if the workspace has no home.
If no route is clear, it asks a person. Agents still reply on the original
task when reporting a result or blocker.

## Existing installs

The migration adds a nullable parent ID and an index. Existing agents stay
at the top level; the migration does not infer reporting lines from names,
instructions, or prior messages. If you roll back and delete or transfer a
manager, any dangling or out-of-workspace parent IDs are treated as no
manager on upgrade. Older imports start flat; newer imports remap valid
reporting links and reject cycles or an over-deep branch.
