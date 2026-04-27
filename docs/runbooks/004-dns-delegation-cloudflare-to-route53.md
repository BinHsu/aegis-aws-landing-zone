<!-- session-close-review: Cloudflare UI screenshots / terminology still match the current Cloudflare dashboard; dig verification commands still produce the shape shown; the 4 NS values in the example reflect the live Route53 zone -->
# 004 — DNS delegation: Cloudflare → Route53 subdomain

> **Forker note**: this runbook walks the delegation pattern using this lab's worked example (`staging.binhsu.org` delegated from Cloudflare-hosted `binhsu.org`). Wherever you see `binhsu.org` in shell snippets or output, substitute your apex domain from `config/landing-zone.yaml` (`domain.name`); wherever you see `staging` as a subdomain label, substitute the environment subdomain you are delegating.

**Scope**: one-time setup to delegate an environment subdomain (e.g., `staging`) from your Cloudflare-hosted apex zone to an AWS Route53 hosted zone. Same shape applies to any future subdomain delegation (e.g., a `prod` subdomain when a prod cut lands).

**Audience**: repo operator with Cloudflare dashboard access for the apex domain.

**Precondition**: Route53 hosted zone exists. `terraform apply` on `staging/edge/` (or `terraform apply -target=aws_route53_zone.staging` for the two-phase apply) creates it and outputs the 4 authoritative nameservers via `terraform output -json delegated_zone_nameservers`.

## Flow at a glance

```
┌──────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
│ Resolver (user/dig)  │─────►│ Cloudflare          │─────►│ Route53 hosted zone │
│                      │      │ (apex zone)         │      │ (delegated subzone) │
└──────────────────────┘      └─────────────────────┘      └─────────────────────┘
                                 "for the subdomain:
                                  go ask the 4 AWS NS"
```

The parent zone (your apex on Cloudflare) carries 4 `NS` records at the subdomain name pointing at the AWS nameservers. Any query for `*.<subdomain>.<your-domain>` gets routed to Route53; everything else stays on Cloudflare.

## Step 1 — get the nameservers from Terraform

```bash
cd terraform/environments/staging/edge
AWS_PROFILE=aegis-staging-admin terraform output -json delegated_zone_nameservers
```

Output shape:

```json
[
  "ns-1414.awsdns-48.org",
  "ns-1594.awsdns-07.co.uk",
  "ns-30.awsdns-03.com",
  "ns-705.awsdns-24.net"
]
```

The four values are the only ones you need; they are stable for the lifetime of the Route53 hosted zone (they do NOT change on apply, restart, etc.). If `terraform destroy` removes the zone and a later apply recreates it, the 4 values WILL change — plan your teardown accordingly.

## Step 2 — add the 4 NS records in Cloudflare

1. Log in to https://dash.cloudflare.com.
2. Select your apex zone from the domain list (the lab's case: `binhsu.org`).
3. Top navigation → **DNS** → **Records**.
4. Click **Add record**.
5. Fill each field exactly:

   | Field | Value |
   |---|---|
   | Type | `NS` |
   | Name | `staging` (no dot, no apex suffix — Cloudflare auto-appends) |
   | Nameserver | (one of the 4 values, no trailing dot) |
   | Proxy status | **DNS only** (🔘 grey cloud) — critical, see gotcha below |
   | TTL | `Auto` (or 300s — anything works) |

6. **Save**.
7. Repeat steps 4–6 **three more times**, one record per remaining nameserver. You should end up with 4 separate `NS` rows at `staging.<your-domain>`.

### Gotcha — Proxy status must be DNS only

Cloudflare's orange-cloud proxy intercepts and re-serves traffic through their CDN. That mode is fine for `A` / `CNAME` records serving a single origin, but `NS` records are metadata pointing at OTHER resolvers — they must resolve to the bare AWS nameserver hostnames, not Cloudflare's proxy. If left as orange cloud, the delegation silently fails: `dig +short NS staging.<your-domain>` returns nothing, or returns Cloudflare IPs instead of the AWS values.

If you accidentally toggled orange cloud: click the cloud icon on the record row, switch to DNS only (grey), save. Propagation is near-instant.

## Step 3 — verify delegation is live

Run from any machine with `dig` (substitute your domain everywhere `binhsu.org` appears):

```bash
# Ask Cloudflare's public resolver
dig +short NS staging.binhsu.org @1.1.1.1

# Ask Google's public resolver (cross-check)
dig +short NS staging.binhsu.org @8.8.8.8

# Ask whatever your machine's default resolver is
dig +short NS staging.binhsu.org
```

All three should return the 4 AWS nameservers (order may differ — DNS rotates them):

```
ns-1594.awsdns-07.co.uk.
ns-1414.awsdns-48.org.
ns-705.awsdns-24.net.
ns-30.awsdns-03.com.
```

If any resolver returns empty or returns non-AWS values, something is off — see troubleshooting below.

**Typical propagation time**: Cloudflare's DNS-only records are ~instant (< 60 seconds). If your `dig` still shows empty after 5 minutes, the Cloudflare record is misconfigured (probably `Name` field or proxy status).

## Step 4 — apply the rest of staging/edge

Once delegation is verified:

```bash
cd terraform/environments/staging/edge
AWS_PROFILE=aegis-staging-admin terraform apply
```

ACM will validate the cert via DNS in Route53 (typically < 5 min). CloudFront distribution provisioning is the slow step (2–15 minutes depending on AWS-side propagation). Total cold apply is ~5 min wait time, ~2 min actual work.

## Rollback

To remove the delegation (e.g. if moving the subdomain to a different provider):

1. On Cloudflare: delete all 4 `NS` records at `staging`.
2. On AWS: `terraform destroy` in `staging/edge/` (this removes the Route53 zone along with everything else).

Order matters: delete Cloudflare records FIRST, then destroy Route53. If you destroy Route53 first, Cloudflare still thinks the delegation is live and users hit an empty authoritative response (SERVFAIL) until Cloudflare records are cleaned up. Not harmful, just ugly.

## Troubleshooting

### `dig` returns SERVFAIL or empty

Most common cause: Cloudflare record has Proxy status = orange cloud. Check step 2 gotcha.

Second most common: wrong `Name` field. If you put the full FQDN (`staging.<your-domain>`) in the Name, Cloudflare interprets it as `staging.<your-domain>.<your-domain>`. Name should be just the subdomain label (`staging`).

### `dig` returns the wrong AWS nameservers

You may have an older zone's NS values if a previous delegation was removed and recreated. Terraform's current output (`terraform output -json delegated_zone_nameservers`) is the source of truth; compare and update Cloudflare.

### `dig` returns some AWS NS, some Cloudflare NS

You added fewer than 4 NS records on Cloudflare, or Cloudflare has additional cached records from a previous state. Delete all `NS` rows at `staging` in Cloudflare and re-add exactly 4.

### ACM validation never succeeds

- Check the DNS validation records actually exist in Route53: AWS Console → Route53 → `staging.<your-domain>` hosted zone → Records should show one `CNAME` with a long ACM-generated name for each SAN on the cert. Terraform creates these in `acm.tf`.
- Check the delegation is propagated: if Cloudflare still serves the parent domain, ACM's DNS validation queries (which go through public resolvers) should still find the records as long as delegation is live.
- ACM retry cadence is ~10 minutes. Be patient; don't interrupt the apply.

### Cloudflare dashboard doesn't offer DNS only (grey cloud) for NS records

Cloudflare disables proxy for `NS`, `TXT`, `MX`, and a few other record types — the orange/grey toggle should be absent or auto-set to grey. If you see orange, you are looking at a different record type. Double-check Type = NS.

## When to repeat this runbook

- **Adding a new environment subdomain** (e.g., delegation for a `prod` subdomain when prod cut lands): same steps, different 4 NS values from a new Route53 hosted zone.
- **Recreating an accidentally-destroyed staging zone**: Terraform output gives new NS values; operator updates the 4 Cloudflare records. Old values pointed at the destroyed zone and will have been auto-cleaned by Cloudflare's lack-of-resolver fallback.
- **Moving the parent domain off Cloudflare**: not covered here. Different runbook — would involve updating registrar-level NS, not per-record NS.

## Why subdomain delegation over full apex move

Covered in ADR-019 §"Alternatives E". Short version: keeps the rest of the apex domain (apex, www, any non-aegis service) managed where the operator already manages it; lower blast radius; reversible by deleting 4 records instead of re-establishing an entire zone on Cloudflare.
