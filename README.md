# ESS Deployment without IPC registration.
_[Element server suite](https://github.com/element-hq/ess-helm) (ESS)_ is a popular open-source communication platform from _[Matrix foundation](https://matrix.org/)_ team.

ESS requires TLS for secure communication, so a domain name is necessity.

However, domains could be somewhat of a hassle in certain server regions.

So this repo will help you avoiding IPC restrictions during deployment,  while keeping it's stability.

# Part 0: HOW?
## 1. First glance, Understand the structure

There are two main layouts, only difference is whether the webscoket relay server has been used.

### Layout A — Main & Media

```
                         ┌───────────────────────────────────────────┐
  sign in, chat, etc.    │ MAIN server                   example.com │
  ───────────────────────▶  matrix. / account. / admin. / mrtc.      │
  "let me join call"     │                                           │
  ───────────────────────▶  hands back: wss://203.0.113.20:7443      │
                         └───────────────────────────────────────────┘
  
                         ┌───────────────────────────────────────────┐
    call signalling      │ LIVEKIT server               203.0.113.20 │
  ───────────────────────▶  TCP 7443 (wss, IP certificate)           │
                         │  TCP 80   (certificate renewal)           │
    audio / video        │                                           │
  ───────────────────────▶  UDP 50000-51000, UDP 3478, TCP 7881      │
                         └───────────────────────────────────────────┘
```

### Layout B — Main, Media & Relay

```
                         ┌───────────────────────────────────────────┐
    sign in, chat        │ MAIN server                   example.com │
  ───────────────────────▶  matrix. / account. / admin. / mrtc.      │
    "let me join call"   │                                           │
  ───────────────────────▶  hands back: wss://203.0.113.30:7443      │
                         └───────────────────────────────────────────┘
                
                         ┌──────────────────────────┐   ┌───────────────────────────┐
    call signalling      │ WSS-RELAY   203.0.113.30 │   │ LIVEKIT      203.0.113.20 │
  ───────────────────────▶  TCP 7443 (wss, IP cert) ├───▶  TCP 7443, self-signed    │
                         │                          │   │                           │
                         │  TCP 80 (cert renewal)   │   │                           │
                         └──────────────────────────┘   │                           │
    audio / video                                       │                           │
  ──────────────────────────────────────────────────────▶  UDP 50000-51000,         │
                                                        │  UDP 3478, TCP 7881       │
                                                        └───────────────────────────┘
```

## 2. Second thought, Why split

### Problems
1. ICP restrictions within mainland China. **This means element server suite simply couldn't be deployed within mainland without ICP**
2. Congested international internet gateway. **This means placing Server Suite outside mainland will cost hugely on media latency & stablity**

### Solutions
Simple, ***just keep media service in, homeserver out***

### Results
1. Homeserver placed outside mainland, ICP bypassed.
2. Media server placed within mainland, ensuring low latency & high stability.
3. ***(additional)*** In case your livekit IDC blocks 80/443, you can reverse-proxy it with **Layout B**.

## 3. Third looking, I know you didn't read through that diagram (*-ω-*)

### Layout A
**LiveKit server**
```
  clients' wss     ─▶ nginx :7443 (IP cert) ──▶  livekit-server 127.0.0.1:7880                                       
  media feed       ─▶ livekit-server   UDP 50000-51000, UDP 3478, TCP 7881
  
  Let's Encrypt    ─▶ ACME challenge   TCP 80, certificate renewal
``` 
**Main server**
```
  internet ─▶ K3s / Traefik:443
                   ├─▶ Synapse                        matrix.<domain>
                   ├─▶ Matrix Authentication Service  account.<domain>
                   ├─▶ Element Admin                  admin.<domain>
                   ├─▶ call login service (JWT)       mrtc.<domain>
                   ├─▶ LiveKit server                 mrtc.<domain>/  → <LiveKit IP>:7443
                   └─▶ well-known                     <domain>
```
### Layout B
**Relay server** 
```
  clients' wss     ─▶ nginx :7443 (IP cert)
                            └─▶ LiveKit server :7443, (Self-signed with custom SNI)
  Let's Encrypt    ─▶ ACME challenge   TCP 80, certificate renewal
```
**LiveKit server**
```
  proxied wss      ─▶ nginx :7443, (Self-signed with custom SNI) ──▶ livekit-server 127.0.0.1:7880
  media feed       ─▶ livekit-server   UDP 50000-51000, UDP 3478, TCP 7881
```
**Main server**
```
  internet ─▶ K3s / Traefik :443
                   ├─▶ Synapse                        matrix.<domain>
                   ├─▶ Matrix Authentication Service  account.<domain>
                   ├─▶ Element Admin                  admin.<domain>
                   ├─▶ call login service (JWT)       mrtc.<domain>
                   ├─▶ LiveKit server                 mrtc.<domain>/  → <LiveKit IP>:7443
                   └─▶ well-known                     <domain>
```

# Part 1: Deploy!

### About repo

Deployment includes 2 or 3 following scripts.
| Order | Script | Runs on | What it sets up |
|-------|--------|---------|-----------------|
| 1 | `setup-livekit.sh` | LiveKit server | The media server that carries audio and video |
| 2 | `setup-relay.sh` | relay server — Optional | A wss relay for call signalling |
| 3 | `setup-main.sh` | main server | The homeserver: chat, accounts, admin console, and the call login service. |

### What you need before start

1. Decide whether you need layout A or B first.
2. Fresh Debian or Ubuntu servers with root access and a public IPv4 address. **Most IDCs' VM satisfy this requirement**
3. A domain you control, It becomes part of every user ID (`@alice:example.com`). **This cannot be changed after installation**.
4. DNS A records pointing at the **main** server:
  - **Homerserver**: `example.com`
  - **Matrix protocal**: `matrix.example.com`
  - **Account**: `account.example.com`
  - **Admin**: `admin.example.com`
  - **Media**: `mrtc.example.com`
5. The LiveKit and relay servers need **no domain**.
6. Open ports in each server's security group:

 - **LiveKit _(layout A)_**: `UDP 50000-51000`, `UDP 3478`, `TCP 7881`, `TCP 7443`, `TCP 80`, all from anywhere.
 - **LiveKit _(layout B)_**: `UDP 50000-51000`, `UDP 3478`, `TCP 7881`, from anywahere. `TCP 7443` from relay & main.
 - **Relay _(layout B only)_**: `TCP 7443`, `TCP 80` from anywhere.
 - **Main**: `TCP 80`, `TCP 443` from anywhere.

### Then we shall...

#### 1. LiveKit server

```sh
sudo bash setup-livekit.sh
```

The same for both layouts. It asks only for optional details and at the end
prints the **LiveKit API key and secret**, this server's **IP and port**, and
(for layout B) the **LiveKit certificate** line. Keep that output.

It always creates the self-signed certificate (for layout B) and tries to get
the IP certificate (for layout A). If port 80 is closed or blocked, the IP
certificate fails; the script says so and carries on. That is expected in
layout B — add `IP_CERT=0` to skip the attempt. Layout A needs it: open port 80
and run the script again.

#### 2. Relay server — layout B only

```sh
sudo bash setup-relay.sh
```

Enter an email address and the LiveKit server's IP, port and certificate line
from step 1. It prints the **LiveKit address** clients will use (`wss://<relay-ip>:7443`).

#### 3. Main server

```sh
sudo bash setup-main.sh
```

It asks for your domain and then:

| Question | Layout A | Layout B |
|----------|----------|----------|
| LiveKit address | `wss://<LiveKit IP>:7443` | `wss://<relay IP>:7443` |
| LiveKit API key / secret | from step 1 | from step 1 |
| LiveKit server IP | press Enter | the LiveKit server's IP |
| LiveKit certificate | not asked | the certificate line from step 1 |

The answers are written to `essconfig.yaml` next to the script
(`livekit_url`, `livekit_key`, `livekit_secret`, `external_livekit_ip`,
`external_livekit_cert`), then
everything is installed. Pressing Enter at the LiveKit address installs chat
without calls; add the values to `essconfig.yaml` later and run the script
again.

#### 4. Create your first user

```sh
sudo k3s kubectl exec -n ess -it deploy/ess-matrix-authentication-service -- mas-cli manage register-user
```

Sign in at `https://account.<domain>`, or add the server `<domain>` in any
Matrix app such as Element, and start a call to test. With the default
`registration: token` setting, other people need an invite token to sign up;
`setup-main.sh` prints the command that creates one.

***Then you are good to go, enjoooooy!***

# Part 2: Some just in cases

## If your element web start to feeling slow
In this case you can whether install desktop app or another web deployment.
### Apps:
- **Element desktop app**: _[element.io](https://element.io/en/download)_
- **Other clients on matrix foundation**: _[matrix.org](https://matrix.org/ecosystem/clients/)_
### New web deployments:

#### Hosting _[Cinny](https://github.com/cinnyapp/cinny)_ on Cloudflare Workers

Cinny is a static web app, so it can live on Cloudflare's free plan: Cloudflare
pulls your copy of the code from GitHub, builds it and publishes it. After the
one-time setup below, every update is a single click.

You need a GitHub account and a Cloudflare account.

**1. Fork Cinny.** Open _[cinnyapp/cinny](https://github.com/cinnyapp/cinny)_
and press **Fork**. You now have `github.com/<you>/cinny`.

**2. Point it at your homeserver.** In your fork, edit `config.json` (the pencil
icon on GitHub is enough) so your server is the only choice on the login page:

```json
  "defaultHomeserver": 0,
  "homeserverList": ["example.com"],
  "allowCustomHomeservers": false,
```

Use your server name (the part after the `:` in user IDs), not
`matrix.example.com`. Leave the rest of the file as it is.

**3. Tell Cloudflare what to publish.** In your fork, press **Add file → Create
new file**, name it `wrangler.jsonc` and paste:

```jsonc
{
  "name": "cinny",
  "compatibility_date": "2025-01-01",
  "assets": {
    "directory": "./dist",
    "not_found_handling": "single-page-application"
  }
}
```

`not_found_handling` matters: without it, reloading the page inside a room
shows "not found".

**4. Connect Cloudflare.** In the Cloudflare dashboard go to **Workers & Pages
→ Create → Import a repository**, sign in to GitHub when asked, and pick your
`cinny` fork. Set:

| Setting | Value |
|---------|-------|
| Project name | `cinny` (must match `name` in `wrangler.jsonc`) |
| Build command | `npm ci && npm run build` |
| Deploy command | `npx wrangler deploy` |

Press **Save and Deploy**. The first build takes a few minutes and ends with an
address like `cinny.<your-account>.workers.dev`.

**5. Use your own address.** `workers.dev` addresses are often unreachable from
mainland China, so attach a domain you manage in Cloudflare: open the worker,
**Settings → Domains & Routes → Add → Custom domain**, and enter e.g.
`chat.example.com`. Cloudflare creates the DNS record and certificate itself.

**Updating later — the one click.** On your fork's GitHub page press **Sync
fork → Update branch**. Cloudflare notices the change and rebuilds and
publishes on its own; your `config.json` and `wrangler.jsonc` are kept.

If a build fails, the log is under the worker's **Deployments** tab. If the
page loads but login cannot find your server, check
`https://example.com/.well-known/matrix/client` opens in a browser — Cinny
reads it to locate your homeserver.
  
## Changing settings and updating

- **Main server**: edit `essconfig.yaml`, run `sudo bash setup-main.sh` again.
  The same command upgrades ESS to the latest chart version. For Helm options
  the config file does not cover, put raw chart values in an optional
  `ess-extra-values.yaml` next to it.
- **LiveKit / relay**: answers are remembered. Run the script again to re-apply
  (it also prints the key and addresses again), with `RECONFIGURE=1` to be
  asked everything again, or with `UPGRADE=1` (LiveKit) to download the newest
  release: `sudo RECONFIGURE=1 bash setup-livekit.sh`
- **Switching layout**: A → B: run `setup-relay.sh`, then set `livekit_url` to
  the relay and `external_livekit_ip` to the LiveKit server in
  `essconfig.yaml`. B → A: set `livekit_url` to the LiveKit server and empty
  `external_livekit_ip`. Run `setup-main.sh` again either way.

`essconfig.yaml` contains secrets. Keep it private and keep a backup.

## Test mode 

`TEST=1` makes each script build a **second, separate copy** next to whatever
is running, with its own names, files and ports. Nothing belonging to the live
setup is stopped, overwritten or restarted; nginx is only reloaded, and a
configuration nginx rejects is removed again before it can take effect.

```sh
sudo TEST=1 bash setup-livekit.sh
sudo TEST=1 bash setup-relay.sh
sudo TEST=1 bash setup-main.sh
```

| Script | Test copy | Default test ports |
|--------|-----------|--------------------|
| `setup-livekit.sh` | service `livekit-server-test`, `/etc/element-rtc-test/`, `/etc/livekit/livekit-test.yaml` | WSS/TLS 17443, media TCP 17881, UDP 52000-52100, TURN UDP 13478, local 17880 |
| `setup-relay.sh` | `/etc/nginx/conf.d/relay-test.conf` | listens on 7444, forwards to 17443 |
| `setup-main.sh` | Kubernetes namespace `ess-test`, settings in `essconfig-test.yaml` | none — shares 80/443, told apart by hostname |

- The LiveKit and relay scripts **ask for each port** in test mode (Enter
  accepts the default) and refuse a port that is already in use. Open the test
  ports in the firewall too.
- Certificates belong to the server, so a test copy shares the ones already
  there. On a LiveKit server without an IP certificate, the test copy tries to
  get one and otherwise runs with the self-signed one only (layout B).
- The test main install needs its **own server name and DNS records**, e.g.
  `test.example.com`, `matrix.test.example.com`, … It refuses hostnames the
  live install already serves, and needs about 2 GB of free memory.
- Each script ends by printing the commands that remove its test copy.

Without `TEST=1`, `setup-livekit.sh` stops instead of taking over if it finds
a LiveKit or an nginx site on its port that it did not install, and
`setup-main.sh` asks before replacing call components left by an older
hand-made setup.

## Debug mode

`DEBUG=1` prints every command as it runs, with line numbers, and sets
LiveKit's own log level to `debug`. Combine freely: `sudo TEST=1 DEBUG=1 bash
setup-livekit.sh`. The trace contains the API secret — do not paste it in
public.

## Running without prompts

Every question has an environment variable; when the script is not attached to
a terminal it never prompts and stops with a message if a required value is
missing. Each script's header lists all its variables.

```sh
# 1. LiveKit — layout A
sudo EMAIL=ops@example.com RTC_HOST=mrtc.example.com bash setup-livekit.sh </dev/null
# 1. LiveKit — layout B (no IP certificate needed)
sudo IP_CERT=0 RTC_HOST=mrtc.example.com bash setup-livekit.sh </dev/null
sudo grep -E '^(LIVEKIT_KEY|LIVEKIT_SECRET|NODE_IP|TLS_PORT)=' /etc/element-rtc/livekit.env

# 2. relay (layout B)
sudo base64 -w0 /etc/element-rtc/tls/internal.crt        # on the LiveKit server: the certificate line
sudo EMAIL=ops@example.com BACKEND_IP=<livekit-ip> BACKEND_CERT=<line> bash setup-relay.sh </dev/null

# 3. main — layout A
sudo SERVER_NAME=example.com ACME_EMAIL=ops@example.com \
     LIVEKIT_URL=wss://<livekit-ip>:7443 LIVEKIT_KEY=... LIVEKIT_SECRET=... \
     bash setup-main.sh </dev/null
# 3. main — layout B
sudo SERVER_NAME=example.com ACME_EMAIL=ops@example.com \
     LIVEKIT_URL=wss://<relay-ip>:7443 EXTERNAL_LIVEKIT_IP=<livekit-ip> \
     EXTERNAL_LIVEKIT_CERT=<line> \
     LIVEKIT_KEY=... LIVEKIT_SECRET=... bash setup-main.sh </dev/null
```

Precedence is environment variable → remembered answer → prompt. On the main
server the variables are only read when `essconfig.yaml` does not exist yet;
afterwards the file is the input.

## Where things are

| Server | Files |
|--------|-------|
| LiveKit | `/etc/livekit/livekit.yaml`, service `livekit-server`, `/etc/nginx/conf.d/element-rtc.conf`, certificates in `/etc/element-rtc/tls/` |
| relay | `/etc/nginx/conf.d/relay.conf`, certificates in `/etc/nginx/certs/` |
| LiveKit, relay | remembered answers in `/etc/element-rtc/*.env` |
| main | `essconfig.yaml`; rendered Helm values in `/etc/ess-setup/values.yaml`; everything runs in Kubernetes namespace `ess` |

## Troubleshooting

| Symptom | Check |
|---------|-------|
| `setup-main.sh` waits a long time, then fails | DNS records or ports 80/443 on the main server. `sudo k3s kubectl get certificate -A` shows which certificates are still pending; `sudo k3s kubectl get pods -n ess` shows what is not running. |
| Calls do not start | From the main server, `curl https://<ip:port in livekit_url>/` must print `OK` with no certificate warning. Login service log: `sudo k3s kubectl logs -n ess deploy/ess-matrix-rtc-authorisation-service` |
| Call connects, no audio or video | UDP 50000-51000, UDP 3478 or TCP 7881 blocked on the LiveKit server, or the public IP given to `setup-livekit.sh` is wrong. |
| Relay or main reports the LiveKit server unreachable | The LiveKit server's firewall must allow TCP 7443 from that server's IP. If it is open, the pasted LiveKit certificate line is wrong or incomplete — copy it again from `setup-livekit.sh`. |
| IP certificate request fails | TCP 80 on that server must be reachable from the internet. If the provider blocks it on the LiveKit server, use layout B. |
| LiveKit will not start | `journalctl -u livekit-server -e` |
| Anything else | Run the script again with `DEBUG=1` to see the exact command that fails. |
