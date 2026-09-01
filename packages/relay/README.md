# karmashala_relay

A dumb pipe between a Karmashala desktop host and a paired phone.

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
| `POST /v1/push/register` | `{tag, token, platform}` → `204`. Stores a push token under an opaque, client-derived 32-hex tag — never a device id or a rendezvous. In memory only. |
| `POST /v1/push` | `{tag, payload}` → `202`. Forwards the opaque base64url ciphertext to FCM for the registered token. `404` unknown tag, `410` token gone (registration dropped), `413` over 4 KiB, `503` when push delivery is not configured. |
| `GET /healthz` | `{"status":"ok","rendezvous":N,"sockets":M,"push_tokens":P,"push_delivery":…,"uptime_s":S}` |

Close codes: `1000` the peer left, `4001` the peer's socket failed, `4408` no
peer arrived in time, `4409` rendezvous busy, `4413` a frame above the size cap,
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

`fly deploy` with the included `fly.toml`, or run the binary behind any TLS
terminator. The same binary is what a user self-hosts; nothing in it is
specific to the PopupBits deployment.
