# Plan of record

The decisions that shape durable-assistants, in one place.

## What things are

| Layer | Name | Notes |
|---|---|---|
| Project | **durable-assistants** | One Rails app for a household or a small team to run their own agents. It ships as two published images, the app and the agent sidecar. |
| Install | one deployment | The images, its settings and its people (`docs/deployments.md`). Sign-in, model accounts, the Google app and the Concourse network are its settings; another install can differ. An install is configuration, never a copy of this code. |
| Agent | one thread | Its own name, address, instructions, model, computer, notes, connectors and routines. Screens say "agent"; the code calls its thread a Conversation. |
| Computer | where its work runs | A Sprite (a small virtual machine), a folder on a machine over SSH, or a folder on this machine in development. Optional. |

## Decisions

1. **Models:** one set of model accounts per install, signed in by its
   admins: a Claude or ChatGPT subscription, or an Anthropic API key. Every
   agent runs on those. `config/pi_durable.yml` lists the models agents may
   choose.
2. **Sign-in:** any OpenID Connect provider, keyed by `sub`. Only listed
   people are admitted, asked on every request. If the provider is down,
   nobody new gets in and people already signed in keep working.
3. **Rails holds the logic and the tools;** the sidecar runs Pi Durable and
   forwards every tool call to Rails. It holds no business rules.
4. **Connectors (MCP):** the contract is Pi's own `mcp.json` entry, at two
   levels: all of a person's agents, or one. Remote servers by URL, plus
   command servers that run on the agent's own computer. Each person connects
   their own accounts.
5. **Approvals:** anything that reaches outside asks the person first, unless
   they answered "Always", or the install allows everything
   (`APP__APPROVALS=allow`). What goes out in the person's own name, an
   iMessage from their phone, asks every time, unless the install approves
   everything (`APP__APPROVE_EVERYTHING=true`). Every call is recorded in its
   thread either way.
6. **Concourse:** one server per install. An agent may hold one identity in
   each of its organizations (networks); a task stays on the network it came
   or went on, and a new send names its network once there are two.
7. **Computers:** one per agent, deleted only with its agent. A Sprite sleeps
   when idle; the platform caps how many are awake.

## Left small on purpose

Tab pile-up from visit_website; a "this can take a minute" message for cold
wakes; Google's Tasks (no MCP server).
