# Edge

The shared reverse proxy for every application on this server. One Caddy owns ports 80, 443 and
443/udp, issues and renews TLS certificates for every domain, and routes each host name to its
application over a Docker network that application provides. The applications themselves publish
no ports, so releasing or stopping one never takes another one's site offline.

```bash
cd edge
cp .env.example .env && chmod 600 .env   # ACME_EMAIL and each application's domain
./scripts/up.sh
```

| File | What it is |
|------|------------|
| `docker-compose.yml` | The `caddy` service, its volumes and one external network per application |
| `Caddyfile` | The global block, the `(access_log)` snippet and `import sites/*.caddy` |
| `sites/cloche.caddy` | Cloche's host names and routes |
| `sites/ledger.caddy` | Ledger's host names (`ledgercloud.bid`, `app.`) and routes |
| `.env.example` | `ACME_EMAIL`, `CLOCHE_DOMAIN` and `LEDGER_DOMAIN` |
| `scripts/up.sh` | Creates missing networks, pulls, starts, validates and reloads Caddy |

## What runs

```
                         :80 / :443 / :443-udp
                                  │
                           caddy (project edge) ── TLS (Let's Encrypt), HTTP→HTTPS
                                  │
                 ┌────────────────┴──────────── one external network per application
            cloche_edge                                         ledger_edge
                 │                                                   │
   cloche-web · cloche-zitadel · cloche-zitadel-login · cloche-seq   ledger-web
   api, billing ── resolve auth.<CLOCHE_DOMAIN> to caddy through a network alias
```

## Documentation

English and Ukrainian, identical structure: **[`docs/en/index.md`](docs/en/index.md)** ·
**[`docs/uk/index.md`](docs/uk/index.md)**. The source tree carries no explanatory comments; every
rationale lives there. Cloche's own routes (`app.`, `auth.`, `logs.`) are described in
[`deploy/docs/en/04-edge/index.md`](../deploy/docs/en/04-edge/index.md).
