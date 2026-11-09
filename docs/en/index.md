# Edge: the shared reverse proxy

> 🇺🇦 [Ця сторінка українською](../uk/index.md) · ⬆️ [README](../../README.md)

`edge` is a Docker Compose project with a single service, `caddy`. It is the only thing on the
server with published ports, and every application behind it is reached over a Docker network.

---

## 1. Why the proxy is its own project

- **Only one process can own 80 and 443.** Two applications on one server need one front door, and
  it cannot belong to either of them.
- **Applications are released independently.** While Caddy lived inside `deploy/`, a Cloche release
  or `docker compose down` would have taken every other site on the server offline with it. Now an
  application's lifecycle touches only its own containers.
- **One place for TLS.** Every domain's certificates, renewals and the ACME account live in one
  volume, behind one configuration.

---

## 2. Layout

```caddyfile
{
	email {$ACME_EMAIL}
}

(access_log) {
	log {
		output stderr
		format json
	}
}

import sites/*.caddy
```

`Caddyfile` holds only what is shared: the ACME account address, the `(access_log)` snippet (one
JSON line per request to stderr, for any site that says `import access_log`) and the import of every
site file. Each application has exactly one file in `sites/`, named after it, holding all of its
host names and routes.

Domains come from the environment: `{$CLOCHE_DOMAIN}` is Caddy's environment-variable syntax,
resolved at start-up, and `docker-compose.yml` passes each variable from `.env` into the container.
Both `Caddyfile` and `sites/` are mounted read-only.

What each Cloche host does and why — `app.`, `auth.` with its h2c hop to Zitadel, `logs.` with
Seq's ingestion paths cut off — is documented with the rest of Cloche, in
[Caddy and TLS](../../../deploy/docs/en/04-edge/index.md).

---

## 3. The contract with an application

1. **One external bridge network per application, named `<app>_edge`.** Neither side owns it:
   `scripts/up.sh` creates every external network listed in `docker-compose.yml` that does not exist
   yet, and the application's deploy script does the same for its own (`deploy/scripts/deploy.sh`
   creates `cloche_edge`).
2. **The application attaches only what needs it**: the services Caddy proxies to, and the services
   that must reach one of the application's public names through Caddy. Databases and internal
   services stay on the application's private networks.
3. **Every upstream gets a unique network alias, `<app>-<service>`** (`cloche-web`, `cloche-zitadel`,
   `cloche-zitadel-login`, `cloche-seq`), and the site file uses only those. Caddy sits on several
   applications' networks at once; if two of them both have a service called `web`, the bare name
   resolves to whichever Docker's DNS returns first.
4. **The application publishes no ports.** Caddy is its only way in.
5. **Applications cannot reach each other.** Each `<app>_edge` network joins Caddy to one
   application only; only Caddy is on more than one.

Caddy's attachment to `cloche_edge` carries the alias `auth.${CLOCHE_DOMAIN}`. When Cloche's `api` or
`billing` resolves `auth.<domain>` to fetch Zitadel's JWKS, it gets Caddy's container address, so the
call goes through the same TLS and routing as a browser's but never leaves the host. The stack does
not depend on the provider supporting hairpin NAT. Remove the alias if Zitadel ever moves to another
machine.

### Applications on this proxy

| Application | Site file | Network | Host names | Upstreams |
|-------------|-----------|---------|------------|-----------|
| Cloche | `sites/cloche.caddy` | `cloche_edge` | `{$CLOCHE_DOMAIN}`, `app.`, `auth.`, `logs.` | `cloche-web`, `cloche-zitadel`, `cloche-zitadel-login`, `cloche-seq` |
| Ledger | `sites/ledger.caddy` | `ledger_edge` | `{$LEDGER_DOMAIN}`, `app.` | `ledger-web` |

Ledger is laid out like Cloche without identity and logs: one nginx container, `web`, serves the
landing page on the bare domain and the SPA with its `/api` proxy on `app.`, telling them apart by
`Host`. Its compose file owes this proxy exactly what Cloche's does — the external network
`ledger_edge`, created by its deploy script if missing, and the alias `ledger-web` on `web` — and
nothing else: with no `auth.` name to resolve, its API stays off `ledger_edge`. Until that stack
runs, Caddy answers `502` on Ledger's names; the certificates are issued as soon as their DNS
records point here.

---

## 4. `.env`

| Variable | | |
|----------|--|--|
| `ACME_EMAIL` | required | The Let's Encrypt account address: expiry warnings and account notices go there |
| `CLOCHE_DOMAIN` | required | Cloche's registered domain. **Must equal `DOMAIN` in `deploy/.env`** — Cloche builds its URLs, CORS origins and Zitadel issuer from that one, and Caddy serves this one |
| `LEDGER_DOMAIN` | required | Ledger's registered domain, `ledgercloud.bid`. Must equal the domain Ledger's own deploy is configured with |

`chmod 600 .env`. It holds no secrets today, but it is gitignored like every other `.env`.

---

## 5. Adding another application

1. **DNS.** Point the A/AAAA records of every host name at this server, before the first start —
   otherwise Caddy retries the certificate with backoff until they exist.
2. **The application's compose file.** Declare the network as external and give each upstream an
   alias; publish no ports:

   ```yaml
   services:
     web:
       networks:
         edge:
           aliases:
             - other-web
   networks:
     edge:
       external: true
       name: other_edge
   ```

3. **`docker-compose.yml` here.** Add the network at the top level and to `caddy`, and pass the
   domain:

   ```yaml
   services:
     caddy:
       environment:
         OTHER_DOMAIN: ${OTHER_DOMAIN:?set OTHER_DOMAIN in edge/.env}
       networks:
         other:
   networks:
     other:
       external: true
       name: other_edge
   ```

4. **`.env` and `.env.example`.** Add `OTHER_DOMAIN`.
5. **`sites/other.caddy`.**

   ```caddyfile
   {$OTHER_DOMAIN} {
   	import access_log
   	reverse_proxy other-web:80
   }
   ```

6. **`./scripts/up.sh`.** It creates `other_edge` if missing, recreates Caddy with the new network and
   reloads the configuration.

---

## 6. Operations

`scripts/up.sh` is the whole workflow, for the first start, a Caddyfile change and an image update
alike:

1. refuses to run without `.env`;
2. creates every external network from `docker-compose.yml` that does not exist;
3. `docker compose pull`, then `docker compose up -d --remove-orphans`;
4. `caddy validate`, then `caddy reload`.

The reload is needed because `Caddyfile` and `sites/` are bind mounts: compose does not see their
contents change, so `up -d` leaves a running Caddy alone. Reloading swaps the configuration without
a restart or dropped connections; a configuration that fails validation stops the script before the
reload, and a running Caddy keeps serving the old one. A container that `up -d` has just
(re)created reads the files at start-up, so validate before an image update.

```bash
docker compose logs -f caddy                                                     # issuance, renewal, errors
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose exec caddy caddy reload  --config /etc/caddy/Caddyfile
```

| Volume | Contents | If you lose it |
|--------|----------|----------------|
| `edge_caddy_data` | Every domain's certificates and the ACME account key | Caddy re-issues on the next start, but repeated loss hits Let's Encrypt's limit of 50 certificates per registered domain per week |
| `edge_caddy_config` | Caddy's autosaved config | Harmless |

**Updating Caddy.** `caddy:2-alpine` follows the latest 2.x; `./scripts/up.sh` pulls it and
recreates the container if the image changed.

---

## 7. Logs

Cloche's `vector` reads this Caddy's output from the Docker socket, matching it by the labels
`com.docker.compose.project=edge` and `com.docker.compose.service=caddy`. Access-log lines are kept
only when the request's host is Cloche's `DOMAIN` or one of its subdomains, so other applications'
traffic never enters Cloche's Seq. Caddy's other lines — certificate issuance, renewals, errors —
are shipped whole, for every domain. See Cloche's
[Logs](../../../deploy/docs/en/07-operations/index.md#4-logs).

Ledger has no log server of its own: its requests are in this Caddy's access log, read with
`docker compose logs caddy` here.

---

## 8. Moving from Caddy inside `deploy/`

Both Caddys want 80 and 443, so the old one must be gone before the new one starts:

```bash
cd deploy && ./scripts/deploy.sh   # creates cloche_edge, removes the orphaned caddy
cd ../edge && ./scripts/up.sh      # the shared Caddy takes over 80 and 443
docker volume rm cloche_caddy_data cloche_caddy_config
```

The sites are down between the two commands, and certificates are issued anew rather than carried
over — acceptable while Cloche is not launched.

---

## 9. Troubleshooting

| Symptom | Cause |
|---------|-------|
| `502 Bad Gateway` | The upstream is not on the application's `<app>_edge` network, or its alias differs from the one in `sites/<app>.caddy`. `docker network inspect cloche_edge` lists the members and their aliases |
| `network cloche_edge declared as external, but could not be found` | The network does not exist yet. `./scripts/up.sh` or the application's deploy script creates it |
| `port is already allocated` on 80/443 | Something else holds the ports — usually the old Caddy from `deploy/`; see §8 |
