# Host forge wrapper — Stage A (read only)

This source is not installed or deployed. It serves only `pr`, `diff`,
`ci-runs` and `ci-jobs` for the agent, workspace and exact repositories
configured by an install. There are no default targets. Other verbs,
including `fetch`, `ci-log`, `ci-artifact` and `push`, are refused
before upstream. There is no write path or receipt.

The [wire contract](CONTRACT.md) covers framing, admission and reply shapes.
See [the host setup](INSTALL.md) for required arguments and the inherited
listener. Core must check the root-owned socket path and root kernel peer
before sending. Core's Rails and sidecar transport/binding are separate;
this change does not enable them.

Git fetches only branch heads or full commit IDs over the configured HTTPS
origin into per-call bare scratch. It never checks out files. Diff compares
the two exact resolved trees (`git diff base..head`), not a merge base.
Both CI reads check run ownership; jobs come only from the verified run's
scoped endpoint. Secret-shaped replies are refused rather than masked.

## Review scope

Only `forge_wrapper/` and a wrapper test step in `config/ci.rb` differ from
the exact base `d1a096abe88d9d1640a431108c153341ee78bd31`. Draft #466
(`9df4d02bff2b919979293ca66596e87538c5b8f4`) remains unchanged.
After committing the successor, review its exact two-dot diff:

```sh
git diff d1a096abe88d9d1640a431108c153341ee78bd31..HEAD
```

## Offline tests

Use Python 3.11+ and Git on Linux. The fixture runs real Git smart HTTP and
a synthetic forge API on loopback; it does not use a real forge or token.
CI runs these tests through `bin/ci`. With network namespace support:

```sh
unshare -Urn sh -c 'ip link set dev lo up &&
  PYTHONPATH=forge_wrapper python3 -B -m unittest discover -s forge_wrapper/tests'
```

For the original intentionally permissive red test stub, set
`FORGE_TEST_RED=1` and restrict discovery to `-p test_denials.py`.
