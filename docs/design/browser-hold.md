# Holding the screen's outgoing sends (#286)

With this on, a form post the screen's browser makes waits on the computer
until a person answers Allow or Deny. Nothing reaches the site before Allow.
Deny, no answer, a lost connection or any error all mean the post is never
sent.

Every post is held, whoever caused it: the agent, a person on the screen or a
script. That makes the earlier blocker moot (#286, 18 Nov): the approval is of
the exact request, not of the click, so it no longer matters who clicked.

## What is held, and what is not

- **Held:** every `POST`, `PUT`, `PATCH` and `DELETE` over HTTPS from the
  screen's browser. This includes page scripts, not only forms.
- **Reviewable:** a URL-encoded or JSON body up to 64 KiB. The card shows the
  site, the method, the path and the fields. A field whose name or type looks
  secret (password, token, card number) is shown as withheld.
- **Refused at once:** anything that can't be reviewed: a bigger body,
  multipart (file uploads), unknown encodings, WebSocket upgrades, plain HTTP
  posts, and HTTP/2 or QUIC. The tunnel terminates TLS and offers only
  `http/1.1` via ALPN, so browsers that support HTTP/2 fall back to HTTP/1.1.
- **The browser's own writes:** refused without a card. A page's request says
  where it came from in Fetch Metadata (`Sec-Fetch-Site`), which no page can
  set or remove; the browser's own say `none`. Chromium checks on its
  on-device model's component every minute with a POST to
  `update.googleapis.com`, and no launch setting or policy stops it. The hold
  refuses each such write and logs one fixed line, so nobody is asked about
  something the agent never did.
- **Not held:** `GET` and `HEAD`, so reading and navigating work. A `GET` form
  is not held either. The agent's shell, command connectors and the sidecar's
  own calls don't go through this proxy. This is not a general network block.

## The objects, each with one job

On the computer (`agent/guest/hold/`, Node, run as its own `hold` user):

| Object | Its one job |
|---|---|
| `ThrowawayAuthority` | Makes a throwaway CA on guest tmpfs and deletes its key file. Boot imports only the public certificate into the browser's NSS database. |
| `SiteCertificates` | Makes and caches the certificate the browser sees for each site. |
| `Tunnel` | Accepts the browser's `CONNECT` on loopback, from the browser's user only, to port 443 only. It terminates TLS and offers only `http/1.1` via ALPN. |
| `RequestReader` | Reads exactly one HTTP/1.1 request within size and time limits, or refuses it. |
| `HeldRequest` | Fixes what would be sent: method, site, path and a digest of the whole body. It also builds the summary with secrets withheld. |
| `Decision` | Waits at most 90 seconds per request for one signed Allow or Deny. The relay presents one card at a time; waiting requests keep their original deadlines. Anything else is Deny. |
| `Upstream` | After Allow only, connects to the real site with normal certificate checks and sends the reviewed bytes once, with no retry and no redirect followed. |
| `EgressRules` | Firewall rules at start: the browser's user may reach only the proxy, and its DNS and QUIC traffic is dropped. |

Between the computer and Rails:

| Object | Its one job |
|---|---|
| `HeldPosts` (sidecar) | In an explicit proof session, reads held requests through the authenticated relay and opens each approval. It reads the answer through the private `/agent/held_posts` callback and signs it. Lost answers are not retried. |
| `Approval` kind `outside_send` (Rails) | Keeps only the redacted preview and the one-use answer. The card has Allow once and Deny, no “always”. “Allowed once” means the sidecar collected approval, not that the site received anything. |

## Images

- **The everyday computer image doesn't change in this PR.** The PR shows its
  build is byte-identical.
- **A separate Dockerfile target, `hold-proof`,** builds from the same stage
  and adds the proxy, `nftables`, `openssl`, `nss-tools`, `util-linux` and
  `iproute2`. The existing `publish` job builds, checks (#295,
  `bin/check-core-images`) and pushes it as `…-agent-hold-proof:<sha>`. No new
  runner, registry, token or credential.
- Turning this on for real agents (an off-by-default setting and the change to
  the everyday image) is a later PR, after the real-computer run.

## Acceptance

The main image is the negative control: a browser-user HTTPS POST reaches
the synthetic site without Allow. It does not have a held decision, a
throwaway CA or the TLS tunnel. On the `hold-proof` image, against a
synthetic site inside the computer:

1. A post is held, and nothing reaches the site until Allow. Then it arrives
   once, byte for byte.
2. Deny, no answer before the limit, a lost relay connection or a stopped
   proxy: nothing reaches the site.
3. A forged, reused or altered answer (another site, path or body) is refused.
4. The CA is made inside the computer at start and trusted only in the
   browser's NSS database. The CA key file is deleted at setup. The key
   lives only in the proxy's memory under the `hold` user until the
   computer is deleted. It is never stored or sent off the computer.
5. Every other outbound connection from the browser's user is refused.
6. A browser left alone for three minutes sends nothing for review: its own
   writes are refused without asking.
7. With TLS 1.2 and 1.3, a client offering `h2` and `http/1.1` gets
   `http/1.1`. A client offering only `h2` gets a no-protocol alert: the
   tunnel never offers `h2`.

Run the local Docker checks from clean commits. The acceptance script writes
the exact build commit and image config digest at the top of each run log,
including the everyday-image identity comparison. PR CI covers the code tests.
The binding acceptance check is the later real-computer run using the digest
published from main. Nothing turns on for agents until that check passes.

That run is on a throwaway Sprite made from the hold-proof image by digest:
`bin/check-hold-proof-sprite sudo -n sprite ssh <name> --` on the Sprites
host. As root inside the Sprite, `agent/test/hold-proof-sprite-guest.sh` first
checks that the hold came up under the platform's own boot (tmpfs, the
nftables table, the proxy as `hold`). It prints its files' checksums, to
compare with the same files copied out of the image. Then it stops the
platform's restarter and computer, and runs `hold-proof-check.mjs` unchanged,
which starts the computer itself as it does in a container.
