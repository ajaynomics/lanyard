# Contributing

Thanks for helping. Lanyard is small and young, so a few plain rules keep it
that way.

- **Read [AGENTS.md](AGENTS.md) first.** It is the guide for people and coding
  agents alike: setup, conventions, where things live and what not to touch.
- **Open an issue first for anything big:** a feature, a new dependency, a
  change to the data model, or anything about approvals or sign-in. A small
  fix can go straight to a pull request.
- **Keep pull requests small and focused:** one change, with its tests and
  its page in `docs/` if behaviour changes.
- **Run the tests and the linter.** `bin/ci` runs everything CI runs: RuboCop,
  the audits, Brakeman, the Rails and browser tests and a production boot.
  A pull request is ready when it passes.
- **AI-assisted contributions are welcome,** on three conditions: you have
  read and run the code you send, you say in the pull request which tools you
  used and for what, and you stand behind the change as your own.
- **Security problems** go through [SECURITY.md](SECURITY.md), never a
  public issue.

No CLA and no sign-off: contributions are under the MIT licence, the same
terms in and out.
