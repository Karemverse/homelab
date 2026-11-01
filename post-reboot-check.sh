#!/bin/bash
# Runs at each boot (post-reboot-check.service)
# and writes a health snapshot so we can verify the server came back cleanly.
LOG=/home/admin/homelab/post-reboot-check.log
{
echo "======================================"
echo "POST-REBOOT CHECK: $(date)"
echo "kernel: $(uname -r)"
echo "uptime: $(uptime -p)"
echo ""
echo "--- waiting up to 120s for docker ---"
for i in $(seq 1 24); do docker info >/dev/null 2>&1 && break; sleep 5; done
echo "--- containers ---"
docker ps --format '{{.Names}}: {{.Status}}'
echo ""
echo "--- expected 10 containers, got: $(docker ps -q | wc -l) ---"
sleep 20
echo "--- NPM vhost checks ---"
curl -sk --resolve photos.homelab.internal:443:100.64.0.10 https://photos.homelab.internal -o /dev/null -w 'photos (immich): HTTP %{http_code}\n' --max-time 15
curl -s -o /dev/null -w 'n8n: HTTP %{http_code}\n' --max-time 15 http://127.0.0.1:5678/healthz
timeout 3 bash -c '</dev/tcp/100.64.0.10/445' && echo 'samba: 445 open on tailnet' || echo 'samba: 445 CLOSED'
echo ""
echo "--- tailscale ---"
tailscale status 2>&1 | head -2
echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
echo ""
echo "--- firewall ---"
sudo -n ufw status | head -8
sudo -n iptables -L DOCKER-USER -n 2>/dev/null | head -4
echo ""
echo "--- smartd / fail2ban / update timer ---"
systemctl is-active smartd fail2ban
systemctl --user -M admin@ list-timers homelab-update.timer --no-pager 2>/dev/null | head -2
echo "CHECK COMPLETE: $(date)"
} > "$LOG" 2>&1
