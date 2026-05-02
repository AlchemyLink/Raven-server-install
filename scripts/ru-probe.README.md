# ru-probe — RU mobile uplink probe agent

`ru-probe.sh` runs from inside Russia on a **mobile carrier connection** and
reports back to the AlchemyLink dashboard whether our RU VPS IP, our Reality
SNI pool, and our DNS names are reachable through that carrier's TSPU and
whitelist filters.

It is the only way we can detect:
- **L3 whitelist drops** — our RU IP fell out of the carrier's CIDR allowlist
- **L7 SNI drops** — one of our Reality SNIs fell out of the DPI allowlist
- **DNS poisoning** — the carrier resolver started returning bogus answers
  for `*.zirgate.com`

A probe from EU or RU broadband sees none of these — they are mobile-only
filters. Without an agent on a real RU mobile uplink, we have zero visibility
into our own censorship-circumvention surface.

---

## What you need

One of:

- An **Android phone in Russia** with mobile data on (Wi-Fi off) → install
  Termux from F-Droid (the Play Store version is unmaintained).
- An **OpenWrt router** with a USB LTE modem and a RU SIM.
- A **Raspberry Pi / single-board computer** with a 4G dongle and a RU SIM.

The agent also needs:

- A **probe token** generated on the EU dashboard
  (`openssl rand -hex 32`, then put it in
  `roles/raven_dashboard/defaults/secrets.yml` as
  `raven_dashboard_external_probe_token` and redeploy the role).
- The list of SNIs we use (defaults are in the example config).
- Optionally: a Telegram bot token + chat ID for fallback delivery when the
  dashboard itself is unreachable.

---

## Termux setup (5 minutes)

```bash
# 1. Install dependencies
pkg update && pkg install bash curl openssl-tool dnsutils netcat-openbsd cronie

# 2. Drop the script + config in $HOME
mkdir -p ~/.config ~/bin
curl -fsSL https://raw.githubusercontent.com/AlchemyLink/Raven-server-install/main/scripts/ru-probe.sh -o ~/bin/ru-probe.sh
chmod +x ~/bin/ru-probe.sh

# 3. Configure (copy and edit)
curl -fsSL https://raw.githubusercontent.com/AlchemyLink/Raven-server-install/main/scripts/ru-probe.conf.example \
  -o ~/.config/ru-probe.conf
nano ~/.config/ru-probe.conf
# Set DASHBOARD_URL, PROBE_TOKEN, TARGET_IP. SNIS / DNS_NAMES defaults are fine.

# 4. One-shot test
~/bin/ru-probe.sh
# Expected: "ru-probe: ok (2026-...)"

# 5. Cron — run every 4 hours
crond
crontab -e
# Add:
# 0 */4 * * * /data/data/com.termux/files/home/bin/ru-probe.sh >> /data/data/com.termux/files/home/.local/state/ru-probe/log 2>&1

# 6. Keep Termux from being killed in the background:
#   - Lock the Termux notification (long-press → "Keep awake")
#   - Disable battery optimisation for Termux in Android settings
```

If you don't want cron, you can also run from `termux-job-scheduler`:

```bash
termux-job-scheduler --period-ms 14400000 --script ~/bin/ru-probe.sh
```

## OpenWrt setup

```sh
# Need bash, curl, openssl-util, bind-tools, netcat. opkg names vary.
opkg update
opkg install bash curl openssl-util bind-dig coreutils-date

mkdir -p /etc /var/lib/ru-probe
wget -O /usr/sbin/ru-probe.sh \
  https://raw.githubusercontent.com/AlchemyLink/Raven-server-install/main/scripts/ru-probe.sh
chmod +x /usr/sbin/ru-probe.sh

wget -O /etc/ru-probe.conf \
  https://raw.githubusercontent.com/AlchemyLink/Raven-server-install/main/scripts/ru-probe.conf.example
vi /etc/ru-probe.conf
# Set DASHBOARD_URL, PROBE_TOKEN, TARGET_IP. STATE_DIR=/var/lib/ru-probe

# Cron via /etc/crontabs/root
echo "0 */4 * * * /usr/sbin/ru-probe.sh >> /var/log/ru-probe.log 2>&1" \
  >> /etc/crontabs/root
/etc/init.d/cron restart
```

## Raspberry Pi / Linux

Standard cron works. Same shape as OpenWrt but using apt to install
dependencies (`apt install bash curl openssl dnsutils netcat-openbsd`).

---

## Verifying it works

After the first successful probe, on the dashboard at `https://dash.zirgate.com/settings`
you should see an **"External Probes"** card with:
- The carrier name we detected (mts / megafon / beeline / tele2 / yota)
- The public IP the agent is using
- A timestamp of the most recent successful submit
- A green / yellow / red status per SNI (TLS handshake outcome)

If after the first run nothing shows up:
1. Check the script's exit on the device: `ru-probe.sh; echo $?`
2. Confirm the token: `curl -i -X POST -H "X-Probe-Token: $TOKEN"
   -d '{"schema":1,"carrier":"mts","public_ip":"1.2.3.4"}'
   https://dash.zirgate.com/api/external/probe-result`
   → expect 204
3. Check the dashboard backend log:
   `journalctl -u raven-dashboard -f` on the EU VPS

## Operational notes

- **One probe per minute is the cap** at the dashboard side; a stuck cron
  firing every second will get 429s. Real cadence is per N hours.
- **Carrier auto-detection** uses ipinfo.io. If that's unreachable from your
  carrier (some carriers block it), the agent will report `carrier: unknown`
  but probes still run normally.
- **Telegram fallback** is per-message Markdown. Don't use HTML / un-escaped
  user input in custom messages — the script doesn't escape Markdown.
- **State** lives in `$STATE_DIR/post-failures` (a single integer counter).
  Wiping `$STATE_DIR` resets the fallback trigger; safe to do.
