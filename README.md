# llama-lan

Serve one local `llama.cpp` inference instance to another machine on your LAN
(for example, a MacBook running Threadline and Engram) without exposing it to
the internet.

- Binds to **one LAN interface address**, never `0.0.0.0`
- Requires an **API key** (`Authorization: Bearer <key>`)
- **CORS locked** to the client's local origin
- Web UI and agent/file tools **disabled**
- Optional native TLS (llama.cpp supports `--ssl-cert-file` / `--ssl-key-file`)

Built on [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT).

## Requirements

- Linux host with `llama.cpp` installed (`/usr/bin/llama` by default)
- `ip`, `ss`, `curl`, `openssl`, `python3`
- Client and host on the same WiFi/LAN

## Setup

```sh
cp config.example.env config.env
$EDITOR config.env            # set IFACE, PORT, MODEL_PRESET, CORS_ORIGINS
chmod +x serve-inference.sh
./serve-inference.sh start
```

The first start generates the API key at
`~/.config/llama-lan/api-keys` (mode 0600). Logs and the pid file live in
`~/.local/state/llama-lan/`.

If the model is already loaded in an interactive `llama cli`, exit it first:
the script refuses to start a second instance that would exceed VRAM.

## Commands

| Command | What it does |
| --- | --- |
| `./serve-inference.sh start` | Start the server (idempotent) |
| `./serve-inference.sh stop` | Stop it and its router children |
| `./serve-inference.sh restart` | Stop then start |
| `./serve-inference.sh status` | Bind address, health, served models |
| `./serve-inference.sh logs [N]` | Tail the server log |
| `./serve-inference.sh key` | Print the API key |
| `./serve-inference.sh rotate-key` | New key (restarts if running) |

## Configure the MacBook clients

Get the two values from the host:

```sh
./serve-inference.sh status   # -> bind: http://<LAN_IP>:8080
./serve-inference.sh key      # -> the bearer token
```

In **Engram** and **Threadline**, set:

- **Base URL:** `http://<LAN_IP>:8080/v1`
- **API key:** the value printed above (sent as `Authorization: Bearer <key>`)
- **Model:** the id returned by `/v1/models`

`CORS_ORIGINS=localhost` permits a local web app served from
`http://localhost:<any-port>`, `http://127.0.0.1:<any-port>`, or
`http://[::1]:<any-port>`. If the app is served from a custom name, set the
exact origin(s) in `config.env`, comma-separated.

### Verify from the MacBook

```sh
export LLAMA_URL=http://<LAN_IP>:8080
export LLAMA_KEY=<key>

curl -s "$LLAMA_URL/health"
curl -s -H "Authorization: Bearer $LLAMA_KEY" "$LLAMA_URL/v1/models"

curl -s -H "Authorization: Bearer $LLAMA_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"hello"}]}' \
  "$LLAMA_URL/v1/chat/completions"
```

Check the browser preflight the way Engram's page will send it:

```sh
curl -si -X OPTIONS "$LLAMA_URL/v1/chat/completions" \
  -H 'Origin: http://localhost:3000' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: authorization,content-type' \
  | grep -i '^access-control'
```

You should see `Access-Control-Allow-Origin: http://localhost:3000`.
A wrong or foreign origin must not be reflected.

If the Mac cannot connect:

1. Approve the macOS "local network" prompt for the browser/app.
2. Check that the WiFi access point is not using client isolation.
3. Check the host firewall (opening ports usually needs root).
4. `401` means the key is wrong; `403`/CORS errors mean the origin is not allowed.

## Security model

This setup deliberately uses **plain HTTP on the LAN**, protected by an API key
and strict CORS:

- The server binds only to the LAN interface address, not to other interfaces.
- The API key is the real access control. CORS only constrains browsers; `curl`
  and other native clients ignore it.
- HTTP traffic is cleartext on WiFi. Use a trusted, WPA3 network. If the key may
  have been observed, run `./serve-inference.sh rotate-key`.
- The key file is `0600` and `config.env` is gitignored. No secrets are committed.
- The Web UI is disabled and llama.cpp's file/agent tools are never enabled.
- Do not add `--tools`, `--agent`, or `--props` to `MODEL_PRESET`.

### Optional TLS

llama.cpp can terminate TLS itself. Generate a self-signed certificate valid for
the host IP, then set `TLS_CERT`, `TLS_KEY`, and `CURL_INSECURE=1` in
`config.env` and restart:

```sh
mkdir -p ~/.config/llama-lan/tls
openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
  -keyout ~/.config/llama-lan/tls/key.pem \
  -out ~/.config/llama-lan/tls/cert.pem \
  -subj "/CN=<LAN_IP>" \
  -addext "subjectAltName=IP:<LAN_IP>"
chmod 600 ~/.config/llama-lan/tls/key.pem
```

Then trust `cert.pem` on the Mac (Keychain Access: System keychain, Always
Trust) or accept the browser warning. Base URL becomes `https://<LAN_IP>:8080/v1`.

## Embeddings

If Engram points its **embeddings** endpoint at this server, a chat model is the
wrong endpoint. Run a second instance on another port with
`--embd-gemma-default` (VRAM permitting), or keep embeddings local on the Mac.
Check Engram's settings before assuming one URL serves both.

## Fork and push

```sh
git config user.name "Your Name"
git config user.email "you@example.com"
git commit --amend --reset-author --no-edit

gh repo create llama-lan --private --source=. --remote=origin --push
# or:
git remote add origin git@github.com:<you>/llama-lan.git
git push -u origin main
```

Keep the repo private if you do not want your interface names or LAN
addresses in public config examples.

## License

MIT. Upstream inference engine: [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp).
