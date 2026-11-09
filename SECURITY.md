# Security

Please report a vulnerability privately, through GitHub: on this repository's
**Security** tab, choose **Report a vulnerability**. Don't open a public issue
or pull request for it.

Say what you found, how to reproduce it, and the commit or image tag you
tested. We aim to answer within a week, fix it on `main`, and credit you in
the release notes if you'd like.

## Scope

In scope: the code in this repository and the two images built from it.
For example:

- signing in, sessions, and who is admitted;
- approvals: an agent acting without the answer its settings say it needs;
- connectors and their tokens, and reaching one person's data from another's;
- the agent sidecar, its callbacks and an agent's computer reaching what it
  shouldn't;
- mail or texts arriving as someone they are not, beyond what `docs/email.md`
  and `docs/phone.md` describe;
- `config/deploy.example.yml` and the deploy hooks.

Out of scope:

- an install you don't run: tell its owner;
- other services Lanyard talks to (model providers, Google, Sprites, voip.ms,
  Concourse): report to them;
- what a model chooses to do within permissions a person granted, unless the
  app let it go further than the documented approval rules;
- denial of service by volume, and social engineering.

Lanyard is before 1.0: only the latest `main` gets fixes.
