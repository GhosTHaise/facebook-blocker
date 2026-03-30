# YouTube Blocker
**Two running modes**

`schedule` — saves a recurring daily config and enforces it either as a foreground watcher, a background daemon (`--daemon`), or via cron (`--install-cron`). The scheduler re-evaluates every 60 s and automatically blocks/unblocks as time windows open and close.

`for` — blocks YouTube right now for a fixed duration (`1h`, `45m`, `2h30m`…), then unblocks automatically in the background without blocking your terminal.

**Schedule options**
```bash
# Default: 08:00-12:00 and 13:00-17:30, weekdays only
sudo ./ytblock.sh schedule

# One window, weekends included
sudo ./ytblock.sh schedule --from 09:00 --to 18:00 --no-second-window --weekends

# Two custom windows, no weekends
sudo ./ytblock.sh schedule --from 08:00 --to 12:00 --from2 14:00 --to2 18:00 --no-weekends
```

**Duration mode**
```bash
sudo ./ytblock.sh for --duration 1h
sudo ./ytblock.sh for --duration 45m
sudo ./ytblock.sh for --duration 2h30m
```

**Surviving reboots** — use `--install-cron` once; it adds a `* * * * *` cron job + a `@reboot` entry so the schedule is enforced automatically without you having to restart the daemon manually.

**Domains blocked** — it covers `youtube.com`, `www`, `m`, `youtu.be`, `youtube-nocookie.com`, and the image/thumbnail CDNs (`ytimg.com`, `yt3.ggpht.com`) so the player actually breaks rather than just redirecting the homepage.

The script only touches `/etc/hosts` (no firewall rules, no system services, no kernel changes). Disabling is completely safe and reversible.

You already have two clean ways to disable it:

**Stop the schedule + unblock immediately**
```bash
sudo ./ytblock.sh unblock
```
This removes all the `ytblock.sh` entries from `/etc/hosts` instantly. YouTube works again. The saved schedule stays on disk so you can resume later.

**Stop the daemon too**
```bash
# Find and kill the background daemon
sudo kill $(cat /var/run/ytblock.pid)

# Then unblock
sudo ./ytblock.sh unblock
```

**Nuke everything (schedule + block + cron)**
```bash
sudo ./ytblock.sh reset
```
Then if you installed the cron entries:
```bash
sudo crontab -l | grep -v ytblock | sudo crontab -
```

**To verify `/etc/hosts` is clean after any of the above:**
```bash
grep ytblock /etc/hosts
# Should return nothing
```

Nothing irreversible is ever done — no iptables rules, no DNS server changes, no system config files modified outside of `/etc/hosts`. If you ever delete the script entirely without unblocking first, you can still manually clean up with:
```bash
sudo sed -i '/managed-by-ytblock.sh/d' /etc/hosts
```
And YouTube comes back immediately. That's your nuclear fallback that requires zero dependency on the script.