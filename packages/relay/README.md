# chitragupta_relay

A dumb pipe between a Chitragupta desktop host and a paired phone.

Two ends open an outbound WebSocket to `wss://<relay>/v1/<rendezvous>`; the
relay pairs them and forwards frames verbatim in both directions. Every frame
is already sealed end to end (XChaCha20-Poly1305), so the relay sees only a
rendezvous id, a frame size and a timing — no content, no session, no identity.
The rendezvous id itself rotates per connection, so it cannot link one device's
connections to each other either.

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
| `--quiet` | `RELAY_QUIET=1` | off |

## Endpoints

| Path | Behaviour |
| --- | --- |
| `GET /v1/<32 hex>` | WebSocket. First socket waits, second pairs, a third gets `409`. |
| `GET /healthz` | `{"status":"ok","rendezvous":N,"sockets":M,"uptime_s":S}` |

Close codes: `1000` the peer left, `4001` the peer's socket failed, `4408` no
peer arrived in time, `4409` rendezvous busy, `4413` a frame above the size cap,
`4429` a lone socket sent more than 8 frames before pairing. (WebSocket only
lets an application send 1000 or 3000-4999, so every refusal is in the 4000s.)

## What it deliberately does not do

- **No content logging.** Lifecycle lines carry counts only, never a rendezvous
  id, never bytes. `--quiet` silences even those.
- **No accounts, no storage, no keys.** Restarting it loses nothing but live
  connections, which both ends reconnect.
- **No fairness between a fast sender and a slow reader.** Frames are capped at
  1 MiB each and new connections are rate-limited per IP, but a paired socket's
  outbound buffer is the OS's — a hostile pair can make the relay hold memory
  proportional to what one end sends and the other has not read. Sized for the
  session API's traffic, not for bulk transfer.

## Deploying

`fly deploy` with the included `fly.toml`, or run the binary behind any TLS
terminator. The same binary is what a user self-hosts; nothing in it is
specific to the PopupBits deployment.
