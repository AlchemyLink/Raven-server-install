# Monitoring v2 — audit and redesign (2026-10-31)

Status: proposal. Scope: the whole observability path of AlchemyLink (EU Xray host,
RU relay, MON host, raven-probe, raven-dashboard, Raven-subscribe) with a specific
focus on detecting Russian TSPU interference (blocking, freezing, shaping,
whitelist episodes) fast and without false alarms.

Companion runbooks: `runbooks/no-ru-activation.md`, `runbooks/whitelist-probe-runbook.md`.
Russian summary of this document is in the PR/chat that introduced it; the English
file is canonical.

---

## 1. Executive summary

1. **Nobody receives any Grafana alert and never has.** All 17 provisioned rules
   evaluate on MON, but the effective Alertmanager configuration has a single
   receiver named `empty` with no integration; `grafana-alerting.yml.j2` provisions
   rules only, no `contactPoints:`/`policies:`, and `grafana.ini` has no `[smtp]`.
   Rules did fire (2026-05-02 DPI, 2026-05-07 raven-probe, 2026-06-09 fallback 403,
   2026-10-28 relay paths) and every one of them went to `/dev/null`.
2. **The dashboard's own Telegram admin alerts are off too.** Prod
   `/etc/raven-dashboard/config.json` has no `telegram_alert_chat_ids`, so the
   external-probe drift watcher never ran (`worker_last_tick_age_seconds{probe_alert_watcher} = -1`)
   and `/feedback` forwarding is a no-op. Per-user quota notices still work because
   they go to the user's own chat.
3. **Server-side DPI detection from Xray logs is dead by construction.** Xray runs at
   `loglevel: warning`; `error.log` is 128 bytes (one "started" line); `access.log`
   (42 MB) contains zero `rejected` records. Reality hands invalid ClientHellos to
   the cover site silently and VLESS logs `invalid request from` at *Info*. The three
   counters `xray_handshake_failure_total / connection_reset_total / probe_detected_total`
   have been exactly 0 since they were created. The fourth,
   `xray_throughput_degradation_total`, is pure noise (9,922 events / 14 d on an
   inbound that is healthy) and would keep the "sustained degradation" rule
   permanently firing if anyone received it.
4. **Every rule has also been failing to evaluate since the Grafana 12 upgrade.** Found
   while deploying Phase 0: all 17 rules reported
   `health=error — [sse.parseError] failed to parse expression [C]: no variable specified
   to reference for refId C`. The threshold expression used the pre-Grafana-12 classic
   shape (`query.params: [A]`) without `expression: A`. History confirms it: every
   transition since 2026-06-09 is recorded as `Error`, not as a real evaluation. Fixed in
   Phase 0 together with delivery; also removed four `tspu-*` rule uids that survived the
   2026-05 rename in Grafana's DB.
5. **What actually works and must be kept:** the push pipeline (vmagent → VM, 0 drops),
   blackbox TLS probes to the two production covers, raven-probe from the RU relay
   (8 targets, 5-min rounds, all OK, TLS p50 ≈ 60 ms to EU), HAProxy active checks
   over AWG/WG/public paths with metrics, per-user/per-inbound traffic from
   xray-stats-exporter and Hysteria trafficStats.
6. **The redesign is four phases.** Phase 0 is configuration only and closes the
   delivery hole in an afternoon. Phase 1 turns raven-probe into a TSPU classifier
   (real-protocol handshake, throughput ladder, QUIC, controls). Phase 2 adds the
   vantage points that matter in 2026 (mobile LTE), reusing the already-shipped
   external-probe ingest. Phase 3 adds user-side liveness. A regional
   "where is mobile internet jammed" map is covered in §8.

---

## 2. Current state (verified live 2026-10-31)

### 2.1 Topology

```
EU vm-xray-main-2 ── vmagent (15 s) ──VPC──▶ MON vm_my_mon: VictoriaMetrics (basic-auth, 14 d) ◀── Grafana 13.0.2
  │  scrapes: xray-exporter :9550, xray-stats-exporter :9551, node, raven-subscribe :9091,
  │           raven-dashboard :8090, blackbox :9115 (2 TLS probes + /health), grafana, VM, vmagent
  └─ over wg0 ──▶ RU relay: node :9100, nginx-exporter :9113, HAProxy :8405, raven-probe :9117
```

16/16 scrape targets up. RU targets 99.86–99.89 % scrape availability over 14 d
(wg0 blips). VM: 9.3 k active series, 704 M rows, 130 MB on disk, 16.8 GB free.

### 2.2 Alert rules (17) and their real-world value

| Group | Rule | Verdict |
|---|---|---|
| critical | xray-down, raven-subscribe-down, eu-server-down, inbound-probe-down, eu-disk-high | keep; `inbound-probe-down` also matches `blackbox_raven-subscribe` (no `inbound` label → empty summary) |
| critical | ru-server-down | **severity warning** although RU is a single point of failure since ru2 was lost (2026-08-12) → critical |
| critical | relay-eu-path-down / all-paths-down / flapping | good, but only on the unmerged PR #50 branch; first evaluation on 10-28 produced `Error` state (expression error) |
| fallback | fallback-disabled-stuck, fallback-denied-requests | keep |
| dpi | dpi-handshake-spike, dpi-rst-spike, dpi-probe-detected | **can never fire** (see §1.3) → remove with the collector, or keep only after loglevel/collector rework |
| dpi | dpi-degradation-sustained | **noise generator** → remove |
| dpi | raven-probe-sni-blocked | regex omits `SYN_DROP` and `TIMEOUT` → an L3 drop toward EU only trips the 30-min "all covers" rule |
| dpi | raven-probe-all-cover-blocked | keep |

Missing entirely: raven-probe stale/down, vmagent remote-write backlog, VM / Grafana
/ vmagent `up`, MON and RU disk, `hysteria_up`, dashboard worker liveness,
sync-drift, Watchdog (dead-man switch).

### 2.3 Probe coverage

| Signal | From | Covers | Gap |
|---|---|---|---|
| blackbox `tcp_tls` | EU → EU public IP | reality-v2 (dl.google.com), xhttp-v2 (www.python.org) | not a client path; fallback (adobe) unprobed by design (Go TLS gets RST) |
| raven-probe | RU DC (Beget) | eu_*/isp_* × python/google/adobe, ctl ya.ru + cloudflare | stdlib TLS (no uTLS), no real VLESS handshake, no throughput, no UDP/QUIC, **one DC vantage** — DC subnets are routinely whitelisted and the Sep-2026 wave was mobile-only |
| HAProxy checks | RU → EU | awg0 / wg0 / public, TLS+SNI every 3 s | ✓ (merge PR #50) |
| xray-stats-exporter | EU | per-user/inbound bytes, hy2 bytes/online | geo/connection series (`xray_*_connections_total`, `xray_user_last_country`) are absent in VM; log counters dead |
| N1 external probe | (none deployed) | pipeline shipped 2026-05-02, never fed | needs a device on a RU mobile uplink |

### 2.4 Hygiene findings

- Grafana `admin` password differs from `grafana_admin_password` in vault (401) — hand-changed.
- `relay-sni.log` on RU frozen since 2026-06-09 (logging disabled, file kept).
- Orphans: `scrape.yml.j2` never rendered, `ssh_tunnel_ru.yml` never imported,
  "EU+Bridge" titles in dpi-detection, `ru-probe.conf.example` lists retired SNIs,
  `vm_my_kg` (expired 2026-10-20) still in inventory, `no-ru-activation.md` queries a
  blackbox instance that no longer exists.
- Every component except nginx_exporter is deployed at `latest` (VM, vmagent,
  node_exporter, blackbox, both Xray exporters, Grafana).
- Retention 14 d is too short for any 30-day SLO; disk allows 90 d trivially.
- Monitoring commits from June (raven-subscribe `/metrics`, fallback alerts, Hy2
  panels, dynamic per-inbound) live only on `feature/fallback-xhttp` and the open
  PRs #47/#50/#53; `origin/main`'s last monitoring commit is 2026-05-28.

### 2.5 Usage snapshot (for SLO baselines)

24 h: xhttp-v2 13.2 GB, fallback 4.3 GB, reality-v2 0 GB (29 GB / 7 d), hy2 2.1 GB
(1 user). 10 of 32 users moved ≥1 MB in 24 h; 11 moved ≥100 MB in 7 d. Only 3
distinct tokens fetched a subscription today (v2box) — subscription fetch alone is a
weak liveness signal; it becomes useful once `profile-update-interval` is served
(§6.3).

---

## 3. How monitoring got here (history, compressed)

| Era | Dates | What it looked like | Why it changed |
|---|---|---|---|
| Bootstrap | 2026-03-28 → 04-04 | VM+Grafana on EU, CompassVPN dashboard, xray-stats-exporter, 5 liveness alerts | needed traffic/user visibility |
| TSPU + bridge | 04-05 → 04-30 | log-derived DPI counters, throughput baselines, bridge exporter on RU, VM moved to RU | censorship pressure; bridge decommissioned (C5) |
| Dedicated MON / A2 | 05-01 → 05-28 | VM+Grafana to `vm_my_mon`, pseudonymised labels, lat/lon and dest-IP dropped, retention 14 d, TSPU→DPI rename, stack-health dashboards | seizure-risk reduction; MON undersized → swap + VM flags |
| raven-probe | 05-07 → | active layered probe from RU peers, dashboard `/ravenprobe`, verdict alerts | passive server metrics cannot tell "blocked" from "idle" |
| Hy2 / fallback | 06-05 → 06-11 | hysteria metrics, raven-subscribe `/metrics`, fallback alerts | reserve transport went live; **never merged to main** |
| Relay HAProxy / EU move | 10-25 → 10-28 | HAProxy multi-path checks + alerts, instance label decoupled from IP, EU IP ban → new droplet | per-IP TCP ban of the old EU address |

The recurring pattern: each wave added *detectors* but delivery (who gets paged) was
never built, and the June work stayed on feature branches. Phase 0 fixes both.

---

## 4. What TSPU does in late 2026 and what each mechanism looks like to a probe

Condensed from Habr 1095490 / 1044396 / 1047442 / 1100978, AVS ISP (2026-09-11),
net4people #490 / #650 / #671, Xray-core #6293 / #6376, FOCI 2026 QUIC paper,
Amnezia postmortem (2026-09-10). Dates are observation dates; constants vary by
operator and region.

| Mechanism | Trigger | Wire symptom | Duration / key | Probe rung that sees it |
|---|---|---|---|---|
| IP / subnet reputation ban | scans + volume stats + SNI↔IP mismatch; whole /24s since Aug | **SYN unanswered and plain HTTP to the same IP fails**; TCP-only on most operators, UDP/ICMP pass | indefinite; new /24 only | `tcp_syn` + `plain_http` both fail from RU, OK from EU |
| Handshake-burst freeze | foreign dst ∧ Chrome/Safari fingerprint ∧ >3 parallel TLS to one SNI within ~60 s, gaps <350–400 ms | SYN OK, ClientHello sent, **no ServerHello**, ~30 s i/o timeout; plain HTTP works | ~120 s keyed (src, SNI); +600 s if fingerprint changes | `plain_http` OK ∧ `tls_hello` timeout; `parallel_hello` 3 pass / 4 fail |
| Volume freeze (16 KB / ~25 pkt) | foreign-IP TLS flow after ~15–20 KB server→client | transfer **stalls at 14–34 KB**, no RST, window open | per flow | `throughput_ladder.bytes_before_stall` |
| Injected RST | SNI/signature match | ECONNRESET right after ClientHello, TTL mismatch | instant | `tls_hello` → TLS_RESET with RST TTL |
| Shaping | operator policy on non-RU dst (Aug: Rostelecom ~40 Mbit cap; Siberia upload 5–10 Mbit, download untouched) | everything works, slow; **upload-only** variants exist | flow/session | `throughput_ladder` download **and upload** speed vs baseline |
| QUIC SNI drop | Initial SNI in registry; **v1 and v2** since autumn 2026 | silent drop (6 s vs 300 ms), no RST | **420 s on the 4-tuple** | `quic` rung with a fresh source port each run; hy2 auth `233` |
| Mobile whitelist (drop-all) | operator switches to allow-list (events, regions, per base station / per SIM) | only whitelisted IP+SNI pass; others often ~64 kbps, 8.8.8.8 dead | hours–days | controls: ya.ru OK ∧ twitter.com dead ∧ UDP 8.8.8.8 dead |
| DNS interference | UDP/53 to foreign resolvers | silent UDP drop, TCP/53 + DoT/DoH fine; NSDI NXDOMAIN | operator | `dns` rung sys vs DoH (exists) + UDP-vs-TCP split |

Two facts drive the design: enforcement is **per operator, per region, often per
base station** (one vantage is worthless; a DC vantage reports false OK), and the
classifier needs a **plain-HTTP control to the same IP** to separate "IP banned"
from "TLS frozen". Non-TSPU false positives to keep out of alerts: sing-box-core
clients failing against Xray ≥ v26.9.8 Reality (X25519MLKEM768), and the balancer's
Observatory cold-start.

---

## 5. Design principles for v2

1. **Delivery before detection.** No new rule until Telegram delivery and a
   dead-man switch exist and are tested by stopping the evaluator.
2. **Symptom + discriminator, not per-rung noise.** Alerts are composed states
   (`ipblock`, `freeze`, `volume_freeze`, `shaping`, `whitelist`, `udp_down`), each
   requiring agreement of ≥2 vantages (or 1 vantage + EU-local control OK) for ≥2
   probe intervals.
3. **Measure the real protocol from where users are.** Reality/XHTTP/Hy2 through an
   actual `xray run` outbound with the production uTLS fingerprint, from RU mobile +
   home + DC. Stdlib-TLS probes stay as cheap layer-1 canaries.
4. **One evaluator.** Keep Grafana-managed alerting (already provisioned, 13.x has
   rule versioning and `AlertRule` APIs); emulate inhibition with `unless`. Revisit
   vmalert + Alertmanager only if rule count exceeds ~40 or inhibition becomes
   unmanageable.
5. **The probe must not burn the relay.** Burst/parallel tests run from a dedicated
   probe IP, ≤ once per 30–60 min, with cool-down; probe traffic uses a separate UUID
   so it can be excluded from user SLIs; volume stays far below anything
   statistically interesting.
6. **Pin everything, merge everything.** No `latest` in production monitoring; June
   and October monitoring work lands on `main` before new features start.

---

## 6. The plan

### Phase 0 — configuration only (½ day, zero user impact)

| # | Change | Where |
|---|---|---|
| 0.1 | Provision `contactPoints:` (Telegram, bot token + admin chat id from vault) and `policies:` (`group_by: [alertname, vantage]`, `group_wait 30s`, `repeat_interval 4h`, severity=critical → same chat with notification sound) | `roles/monitoring/templates/grafana-alerting.yml.j2`, `defaults/secrets.yml` |
| 0.2 | `Watchdog` rule (always firing, `repeat_interval 24h`) → Telegram: one message a day proves evaluation + delivery; plus `monitoring-heartbeat.timer` on EU (checks Grafana/VM health over the VPC every 5 min, posts to Telegram on state change) so a dead MON is reported from outside MON | same template; `tasks/heartbeat.yml` |
| 0.3 | Set `raven_dashboard_telegram_alert_chat_ids` in the dashboard vault → probe drift watcher + `/feedback` start working | `roles/raven_dashboard/defaults/secrets.yml` |
| 0.4 | Prune: remove `dpi-degradation-sustained`, `dpi-handshake-spike`, `dpi-rst-spike`, `dpi-probe-detected` (and the tspu/throughput collectors in xray-stats-exporter at the next release); fix `raven-probe-sni-blocked` regex (`+SYN_DROP|TIMEOUT`); scope `inbound-probe-down` to `job=~"blackbox_vless.*"`; `ru-server-down` → critical | template |
| 0.5 | Add: `raven-probe-stale` (`time() - raven_probe_last_run_timestamp_seconds > 900` with `raven_probe_up == 1`), `raven-probe-down` (`up{job=~"raven-probe.*"} == 0`, 5 m), `vmagent-remotewrite-backlog` (`vmagent_remotewrite_pending_data_bytes > 50e6` 10 m), `mon-stack-down` (`up{job=~"victoriametrics|grafana|vmagent"} == 0`), `mon-disk-high`, `ru-disk-high`, `hysteria-down` (`hysteria_up == 0`, 5 m), `dashboard-worker-stuck` (`raven_dashboard_worker_last_tick_age_seconds > 3600`) | template |
| 0.6 | Retention 14 d → 90 d; pin VM / vmagent / blackbox / node_exporter / Grafana / exporter versions; reset Grafana admin password from vault | `defaults/main.yml`, `victoriametrics.service.j2` |
| 0.7 | Merge order: #47 → #49 → #50 → #53 (+ #46 Xray pin, #48 edge firewall); then delete `scrape.yml.j2`, `ssh_tunnel_ru.yml`, bridge titles, `vm_my_kg` | git |
| 0.4b | Add `expression: A` to every threshold model (Grafana ≥12 requirement; without it every rule is `health=error`), `noDataState: OK` on `== 0`-style rules (avoids `DatasourceNoData` noise), `deleteRules` for the legacy `tspu-*` uids | template |
| 0.8 | Send a **test alert** end-to-end (stop blackbox for 3 min; expect Telegram within 5 min; expect Watchdog "missing" when Grafana is stopped for 10 min) | runbook |

### Phase 1 — raven-probe v0.2: from "is the SNI reachable" to "which TSPU mechanism" (1–2 weeks)

New rungs per `vantage × target`, each emitting `raven_probe_rung_ok{vantage,target,rung}`
and `raven_probe_rung_duration_ms`:

| Rung | What | Classifier use |
|---|---|---|
| `dns` (exists) | sys vs DoH + **UDP vs TCP** to 8.8.8.8 | DNS interference / whitelist |
| `tcp_syn` (exists) | connect :443 | IP ban |
| `plain_http` **new** | tiny HTTP/1.1 GET to the **same IP** on :80 (`/healthz` on EU nginx and on relay) | separates IP ban from TLS freeze |
| `tls_hello` (exists → uTLS) | one ClientHello with cover SNI, **uTLS profile = the one subscriptions ship** + a Firefox variant; record RST TTL | freeze vs injection vs fingerprint-specific penalty |
| `proto` **new** | real outbound via embedded/forked `xray run` (Reality-Vision, XHTTP, fallback) → local SOCKS → `GET https://<own 204 endpoint>`; export connect / appconnect / starttransfer | the only true "can a user connect" SLI |
| `throughput_ladder` **new** | through the tunnel: 8 KB, 32 KB, 256 KB, 4 MB download with per-chunk timestamps + 1 MB upload; `raven_probe_bytes_before_stall`, `raven_probe_speed_bps{dir}` | volume freeze (stall at 14–34 KB) vs shaping (slow, no stall) |
| `quic` **new** | QUIC Initial v1 + v2 with SNI to hy2 masquerade, **new source port per run**; then hy2 `POST /auth` with a probe-only user → expect `233` | UDP path state (`udp_silent` / `handshake_ok` / `auth_ok`) |
| `controls` **new** | ya.ru (whitelisted), twitter.com (known-blocked), 8.8.8.8 UDP | whitelist-episode recognition |
| `parallel_hello` **new, opt-in** | 1 / 3 / 4 / 6 simultaneous ClientHellos to one SNI within 300 ms; count ServerHellos | burst detector presence; **only from a dedicated probe IP**, ≤ 1/h, 180 s cool-down |

Derived state per `(vantage, transport)` as a recording rule → Grafana state
timeline (ok / ipblock / freeze / volume_freeze / shaping / whitelist / udp_down /
probe_down). Composite rules (all `for: 10m`, need ≥2 vantages or 1 vantage +
EU-local OK):

- `TSPU_IPBlock`: `tcp_syn` ∧ `plain_http` fail from RU, OK from EU.
- `TSPU_Freeze`: `plain_http` OK ∧ (`tls_hello` timeout ∨ `proto` fail).
- `TSPU_VolumeFreeze`: `bytes_before_stall` between 10 KB and 40 KB on ≥2 vantages.
- `TSPU_Shaping`: `speed_bps` < 20 % of 7-day same-hour baseline for 30 m, no stalls (download and upload separately).
- `Whitelist_Episode`: controls pattern (ya.ru OK ∧ twitter dead ∧ 8.8.8.8/udp dead) — informational, and used with `unless` to suppress the others.
- `UDP_Down`: hy2 auth fails ∧ TCP transports OK.

Hygiene: fixed-jitter schedule (±30 %); 2–3-minute sessions rather than single
requests (blocks appear with delay); probe user has its own UUID; alternate SNIs
between parallel tests; never `randomized` uTLS; refresh uTLS profile together with
Xray bumps. Keep `raven-probe` ≤ 15 MB RSS so it still fits a phone.

Also in Phase 1 (server side): nightly `ByeByeVPN --json` from EU against the
relay and EU IPs as a detectability regression gate (alert when the score drops or
a new named signature appears); restore geo/connection series in
xray-stats-exporter (per-ASN accepted-connection rate is the server-side early
warning for a mobile-operator ban); keep Xray at `loglevel: warning` (raising it
buys little and costs disk and privacy).

### Phase 2 — vantage points that matter (hardware + 2–3 days)

Everything in Aug–Oct 2026 was operator- and mobile-specific, so the minimum
useful set is:

| Vantage | Hardware | Uplink | Transport to MON |
|---|---|---|---|
| `ru-dc` (exists) | RU relay | Beget | wg0 scrape |
| `ru-home` | existing home box / RPi | home ISP (note: symmetric NAT breaks WG data-plane tests, TCP/TLS rungs fine) | **push** |
| `ru-mobile-a`, `ru-mobile-b` | cheap Android (Termux + arm64 binary) or RPi + LTE modem, 2 SIMs (e.g. MTS + MegaFon; MegaFon is the strictest per #650) | LTE | **push** |

Push path: reuse the shipped N1 pipeline. raven-probe gains `--push-url` →
`POST /api/external/probe-result` on the dashboard (X-Probe-Token, HTTPS via the
relay/CF front); the dashboard stores and **re-exports the last result as metrics**
on its `/metrics` (`raven_external_rung_ok{vantage,carrier,region,target,rung}`),
which vmagent already scrapes. No new ports, no VPN from phones to MON, no vmagent
on devices. SIM/region/carrier labels come from the device config, not from IP
geolocation. If a phone goes dark, `raven-probe-stale{vantage}` fires — which is
itself a signal (whitelist mode usually kills the push too, so the dashboard keeps
the *last* result with a timestamp and the alert text says "stale since").

Globalping and RIPE Atlas RU probes stay as free secondary controls for rungs 2–4
(arbitrary SNI, no credentials) — see §8.

### Phase 3 — user-side liveness (1 week, mostly Raven-subscribe)

- Serve `profile-update-interval: 2` (hours), `subscription-userinfo`, and
  `check-url-via-proxy`/`ping-type` headers for Happ/INCY clients; point every
  client's "real delay" URL at **our own 204 endpoint** behind the relay. Each such
  hit is a per-token liveness ping that traverses the real path.
- Raven-subscribe emits `raven_sub_last_fetch_timestamp{token_hash}` and
  `raven_ping_last_seen_timestamp{token_hash}` (pseudonymised like the exporter).
- Composite SLI: "fetched subscription or pinged in the last 3 h ∧ zero bytes in
  xray/hy2 stats" per user → `users_dead_ratio`; alert when > 30 % for 30 min.
  This catches breakage that no probe can (client-version incompatibilities,
  sub-token rotation misses, per-ISP bans on the relay IP).

### SLIs / SLOs (30-day window, once Phase 1–2 data exists)

| SLI | Definition | SLO |
|---|---|---|
| Connect success | `proto` rung ok within 5 s, per transport × vantage (mobile weighted ×2) | 99 % XHTTP primary, 97 % Reality fallback |
| TTFB | `starttransfer` p95 | < 2 s mobile, < 1 s home |
| Throughput | 4 MB download p50; stall ratio (`bytes_before_stall` < 40 KB) | > 5 Mbit/s; < 1 % |
| UDP path | hy2 auth 233 success | 95 % (informational while hy2 is reserve) |
| Active share | users ≥1 MB/24 h ÷ enabled (xray + hy2) | alert on −40 % vs 7-day same-hour |
| Dead-user ratio | Phase 3 composite | < 10 % |

Alert tiers: critical (page, sound) = connect-success burn rate 14.4× over 1 h/5 m
or 6× over 6 h/30 m; warning = daily digest. Retention 90 d + recording rules keep
the SLO series cheap.

---

## 7. What we deliberately do not do

- No vmalert/Alertmanager/VictoriaLogs yet — one evaluator, one dashboard host.
- No `loglevel: info` on Xray — privacy and disk cost outweigh the one extra signal.
- No probing from the relay's user-facing IP with burst tests.
- No reliance on public CIDR/whitelist lists — #650 shows they are wrong both ways;
  only a same-day probe over the actual SIM against the actual /24 counts.

---

## 8. Regional "where is the internet jammed" map — feasibility

Short answer: **yes, as an org-private layer built mostly from existing feeds plus
our own passive sensor; no, as a public crowd map or a modem fleet.**

### 8.1 What already exists (reuse)

| Source | Gives | Granularity | Access | Mobile vs fixed | Use |
|---|---|---|---|---|---|
| **Taucloud whitelist map** (taucloud.ru/belye-spiski/karta) | per-minute "whitelist on/off" from own LTE modems + google.com canary, 30-min debounce | operator × federal district (14 operators, 8 FDs + Kaliningrad/Crimea) | CSV + JSON, **CC BY 4.0** | mobile | primary whitelist layer; check its freshness flag per day |
| **IODA v2** (api.ioda.inetintel.cc.gatech.edu) | BGP / active ping / darknet / Google-traffic outage signals | **85 RU regions**, ASN | keyless JSON, windows ≤ 31 d | via mobile ASNs | hard-outage layer; blind to whitelist mode (BGP and ping stay up) |
| **OONI aggregation API** | web_connectivity / DNS / TLS anomalies, ~200 k RU results/day in Oct 2026 | country + ASN, `network_type` wifi/mobile | free REST, raw on S3 | **yes** | per-operator anomaly trend; ship one OONI Run v2 link with our canaries to users (opt-in) |
| **RIPE Atlas** | ping / traceroute / DNS / TLS from 604 connected RU probes | probe (ASN + geo) | REST, credits | mostly fixed | fixed-line/transit control with arbitrary SNI |
| **Cloudflare Radar** | outage annotations, traffic anomalies | country, ASN | token, CC BY-NC | via ASN | secondary confirmer; low RU recall in 2026 |
| **«На связи» / timeline-ru.net** (OZI + eQualitie) | shutdown-days per region (≥2 operators disrupted) | region / day | no API; `@Na_svyazi_helpdesk_bot` | mobile | best regional ground truth — ask for a data-sharing arrangement, don't scrape |
| hxehex / rewl / dpi-checkers lists | whitelisted SNI/CIDR sets | nationwide, per-ASN | GitHub | mobile | canary design input only (lists are wrong both ways per #650) |
| Сбой.рф / Downdetector.su / Detector404, RKN «Мониторинг сбоев» | crowd complaints | city | none | no | noise; bot-generated peaks (Apr 2025); RKN brands Detector404 a fake vector |
| GlobalCheck | router sensors (2 cities, 5 operators in 2024) | city × operator | none | yes | apparently defunct since ~Mar 2025 — don't depend on it |

### 8.2 What nobody provides (build, small)

1. **Passive server-side sensor** (Amnezia-Pulse model). On EU and relay:
   per-(operator ASN, declared region, wifi/mobile) handshake success, bytes,
   first-hop RTT in 5-min bins against a 14-day baseline; client IPs dropped after
   aggregation. This is the only thing that says whether *our* Reality/XHTTP/Hy2
   paths are jammed on MTS-Omsk vs MegaFon-SPb. ~1–2 days on top of
   xray-stats-exporter (restore the ASN series) + recording rules.
2. **Whitelist canary endpoint in the Telegram bot / portal.** User taps "Проверить
   связь": the client fetches (a) our EU/relay IP, (b) a whitelisted Yandex IP with a
   benign SNI, (c) 8.8.8.8 UDP/53, (d) UDP/443 to a whitelisted host. The 4-bit
   result + ASN + user-picked region classifies `open / whitelist / full shutdown /
   SIM cooling period` (the 24-h cooling after roaming or >72 h offline mimics a
   shutdown and must be a separate class). Stored aggregated only.
3. **Region map UI** (org-private Grafana geomap or dashboard page): join (1)+(2)
   with Taucloud districts and IODA regions. States per region × operator:
   open / whitelist / shutdown / unknown, with age.

### 8.3 Why not the obvious alternatives

- **Own modem fleet across regions**: SIM caps (20 per citizen), 72-h idle → 24-h
  cooling, IMEI↔SIM registry phasing in from 2027, and Taucloud already does this.
- **Client-side scanning from users' SIMs** (masscan-style): legal/ethical exposure
  under the VPN-detection "методичка" (region-toggling patterns) and KoAP 13.53;
  never push sweeps to users.
- **IP → region from GeoIP**: mobile CGNAT gives ~30 % city accuracy; gateways sit
  up to ~200 km away; RU operators publish no region-granular geofeeds. ASN →
  operator is reliable; **region must come from the user/probe, not the IP**.
- **Public map**: Detector404 precedent — RKN frames crowd maps as fake-injection
  vectors. Keep it private/org-shared.

### 8.4 Legal constraints that shape it (brief)

Since 2025-09-01: fines for *deliberate search* of extremist-list material (13.53)
and VPN *advertising* (14.3); VPN use itself is not an offence. FSB shutdown law in
force 2026-03-03. Consequences: canaries must be neutral (google, Cloudflare, our
own domain), bot/UI wording must not read as VPN advertising, probes must not
toggle VPN on/off from one SIM in a pattern.

### 8.5 Minimal viable map (what to do first)

1. Cron on MON: pull Taucloud JSON + IODA RU regions daily → VM metrics
   `ext_whitelist_mode{operator,district}`, `ext_outage_score{region}`.
2. Phase 2 mobile vantages push `raven_external_rung_ok{carrier,region,…}`.
3. Bot "Проверить связь" canary (Phase 3) → `canary_result{class,asn,region}`.
4. One Grafana geomap/state-timeline over the three; «На связи» monthly digest as
   the human cross-check.

---

## 9. Sources

- Habr 1095490 (2026-10-16) TSPU overview · 1044396 (2026-06-06) burst-freeze reverse engineering · 1047442 (2026-06-15) fingerprint freeze · 1100978 (2026-10-29) QUIC v1/v2 drop re-measurement · 1091260 (2026-10-08) Moneta TSPU localisation with `nping` · 1083838 (2026-09-19) Hysteria2 probing · 1080534 Amnezia postmortem
- AVS ISP, "Three ways Russia breaks your Xray server" (2026-09-11)
- net4people/bbs #490 (16 KB counter), #650 (mobile whitelist), #671 (Aug/Sep IP-ban waves)
- XTLS/Xray-core #6293, #6376, discussions #6525; sing-box #4520
- FOCI 2026, Heitmann et al., QUIC SNI filtering by TSPU
- kutovoys/xray-checker · niktimf/remnawave-healthcheck · lilendian0x00/xray-knife · pwnnex/ByeByeVPN · hyperion-cs/dpi-checkers · ku78/tspu-checker
- VictoriaMetrics docs: vmalert, stream aggregation, retention; Grafana what's-new 12.0 / 13.0 / 2026-10-22 AlertRule API; Google SRE Workbook, alerting on SLOs; Happ dev-docs app-management
- Measurement ecosystem: Taucloud whitelist map (CC BY 4.0, CSV/JSON) · IODA v2 API (85 RU regions) · OONI aggregation API / OONI Run v2 / data policy (`network_type`) · RIPE Atlas probes API + credits · Cloudflare Radar outages API (CC BY-NC) · «На связи» methodology (Meduza 2025-10-16, timeline-ru.net/about) · Amnezia shutdown digest Apr 2026 · Vigo/Kommersant 2026-08-05 whitelist-share numbers · Habr 1027276 (whitelist scan over MegaFon SIM, 2026-04-25) · hxehex/russia-mobile-internet-whitelist · openlibrecommunity/twl→rewl · ACF/FBK "Access Denied" (2026-03) · NANOG 96 / ipregistry on mobile CGNAT geolocation
- Legal: KoAP 13.53 / 14.3 / 13.52 (in force 2025-09-01); FSB shutdown law (in force 2026-03-03); Mintsifry SIM cooling-period order (2025-11-19); 210-FZ IMEI registry (2026-06-26); Mintsifry VPN-detection guidance to IT companies (2026-04)
