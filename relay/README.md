# karmashala_relay

A dumb pipe between a Karmashala desktop host and a paired phone.

Two ends open an outbound WebSocket to `wss://<relay>/v1/<rendezvous>`; the
relay pairs them and forwards frames verbatim in both directions. Every frame
is already sealed end to end (XChaCha20-Poly1305), so the relay sees only a
rendezvous id, a frame size and a timing — no content, no session, no identity.
The rendezvous id itself rotates per connection, so it cannot link one device's
connections to each other either.

The contract below — routes, rendezvous and token rules, push bodies, status
and close codes — is code in [`protocol/`](protocol/lib/karmashala_relay_protocol.dart)
(`karmashala_relay_protocol`), which this server and every client of it
import. It sits inside this folder so the Dockerfile's build context carries it.

## Running it

```
dart pub get
dart run bin/relay.dart --port 8787
```

Flags (each also readable from the environment):

| Flag | Variable | Default |
| --- | --- | --- |
| `--port` | `PORT` | 8787 |
| `--address` | `RELAY_ADDRESS` | 0.0.0.0 |
| `--lone-timeout-s` | `RELAY_LONE_TIMEOUT_S` | 120 |
| `--connections-per-minute` | `RELAY_CONNECTIONS_PER_MINUTE` | 60 |
| `--max-rendezvous` | `RELAY_MAX_RENDEZVOUS` | 10000 |
| `--token-file` | `RELAY_TOKEN_FILE` | none — the relay is open |
| `--quiet` | `RELAY_QUIET=1` | off |

## Access token (optional)

An open relay on a public address is a free forwarder for anybody who finds it:
any two sockets that agree on 32 hex characters get a pipe. `--token-file PATH`
names a file holding 32 or more url-safe characters, and the relay then serves
**every** route — the rendezvous WebSocket, both push endpoints and `/healthz` —
only under `/k/<token>/`. Everything else, a wrong token included, answers the
same `404` an unknown path does.

Clients need no change: they are given the base URL `ws://host:8787/k/<token>`
and append `/v1/<rendezvous>` to it, keeping the prefix.

It is a file and never a flag, because argv is readable by every user on the
machine. The relay never logs it.

**What it is not.** Over plain `ws://` the token is in the request line, so
anyone on the path between a client and the relay can read it. It stops
drive-by use by whoever scans for the port; it is not confidentiality and adds
none — the frames are sealed end to end with or without it. Put the relay behind
a TLS terminator if the token itself has to stay private.

## Endpoints

| Path | Behaviour |
| --- | --- |
| `GET /v1/<32 hex>` | WebSocket. First socket waits, second pairs, a third gets `409`. |
| `POST /v1/push/register` | `{tag, token, platform}` → `204`. Stores a push token under an opaque, client-derived 32-hex tag — never a device id or a rendezvous. In memory only. |
| `POST /v1/push` | `{tag, payload}` → `202`. Forwards the opaque base64url ciphertext to FCM for the registered token. `404` unknown tag, `410` token gone (registration dropped), `413` over 4 KiB, `503` when push delivery is not configured. |
| `GET /v1/hooks/<64 hex>` | WebSocket: a server's webhook listener, presenting its secret listen key. The relay derives the public listen id from it (first 16 bytes of SHA-256 over `karmashala-hooks-listen:<key>`), says `{"type":"ready","listen":…}`, and forwards calls to it. A newer listener for the same id replaces the older (`4410`). |
| `POST /h/<listen id>/<hook id>` | A webhook call, from anywhere. Forwarded as one `call` frame (method, a fixed set of headers, the caller's IP, the raw body in base64) and answered with the server's `answer` frame's status and small JSON body. `405` any other method, `404` a malformed path, `413` over 256 KiB, `429` over 60 calls a minute per listen id, `503` no listener, `504` no answer within 10 s, `502` an answer that breaks the contract. Bodies are held only while in flight. |
| `GET /healthz` | `{"status":"ok","rendezvous":N,"sockets":M,"push_tokens":P,"push_delivery":…,"hook_listeners":L,"uptime_s":S}` |

Close codes: `1000` the peer left, `4001` the peer's socket failed, `4408` no
peer arrived in time, `4409` rendezvous busy, `4410` a hooks listener was
replaced by a newer one, `4413` a frame above the size cap,
`4429` a lone socket sent more than 8 frames before pairing. (WebSocket only
lets an application send 1000 or 3000-4999, so every refusal is in the 4000s.)

## Push delivery (optional)

Push is how a paired phone hears "a session needs you" while it is not
connected. The host seals the notification with the phone's device key and
posts the ciphertext here; the relay holds only `{opaque tag → push token}`
and forwards bytes it cannot read to FCM, which cannot read them either — the
phone decrypts and renders the text locally.

Off by default. To enable it on a self-hosted relay:

1. Create a Firebase project and a service account with the
   **Firebase Cloud Messaging API** enabled; download its JSON key.
2. Point the relay at it: `RELAY_FCM_SERVICE_ACCOUNT=/path/to/key.json`
   (or `--fcm-service-account /path/to/key.json`). On Fly:
   `fly secrets set RELAY_FCM_SERVICE_ACCOUNT=/run/fcm.json` plus a mounted
   secret file, or bake the path into your own image.
3. The startup log says `push delivery via fcm`; without the variable it says
   `push delivery not configured` and `/v1/push` answers `503`.

Registrations live in memory: a restart forgets them, and the host
re-registers automatically when its next push answers `unknown tag`.

## What it deliberately does not do

- **No content logging.** Lifecycle lines carry counts only, never a rendezvous
  id, never a push tag, token or payload, never bytes. `--quiet` silences even
  those.
- **No accounts, no storage, no keys.** Restarting it loses nothing but live
  connections, which both ends reconnect.
- **No fairness between a fast sender and a slow reader.** Frames are capped at
  1 MiB each and new connections are rate-limited per IP, but a paired socket's
  outbound buffer is the OS's — a hostile pair can make the relay hold memory
  proportional to what one end sends and the other has not read. Sized for the
  session API's traffic, not for bulk transfer.

## Deploying

Each release publishes the relay as an image, so running one needs no Dart:

```
head -c 30 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > token
docker run -d -p 8787:8080 -v "$PWD/token:/token:ro" -e RELAY_TOKEN_FILE=/token \
  ghcr.io/lohanidamodar/karmashala-relay:latest
```

(`latest`, or a version such as `1.31.0`; leave out the token for an open
relay.) `fly deploy` with the included `fly.toml` builds the same thing. On a
machine without Docker, the server's installer sets the relay up as a service:
`install.sh --relay` (`install.ps1 -Relay` on Windows), see the top-level
README's *Self-hosting* section. Run any of them behind a TLS terminator for
`wss://`. Nothing in the relay is specific to the PopupBits deployment.
