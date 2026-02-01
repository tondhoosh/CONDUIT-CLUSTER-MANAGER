# DevOps Review & Production Hardening Report

**Reviewer**: Senior DevOps Engineer  
**Review Date**: 2026-02-01  
**Architecture Version**: High-Performance Cluster Edition v2.0  
**Target Environment**: 2vCore / 4GB RAM VPS (Production)  
**Risk Level**: **MEDIUM-HIGH** (First deployment of load-balanced architecture)

---

## Executive Summary

After reviewing the architecture plans, I'm giving this a **CONDITIONAL APPROVAL** for production deployment. The design is sound, but there are critical operational gaps that need addressing before you run this in prod.

### TL;DR Verdict

✅ **GOOD**: Solid Nginx LB design, proper resource calculations, Psiphon compliance  
⚠️ **CONCERNS**: Missing monitoring, no health checks, weak failure recovery  
❌ **BLOCKERS**: No rollback testing, missing operational runbooks, insufficient logging  

**Recommendation**: Deploy to staging first, run chaos tests, then prod with phased rollout.

---

## 1. Critical Production Issues

### 🔴 BLOCKER #1: No Nginx Health Checks

**Issue**: Current Nginx config has no backend health monitoring.

```nginx
# CURRENT (DANGEROUS)
upstream conduit_tcp_443 {
    least_conn;
    server 127.0.0.1:8081;  # What if this dies?
    server 127.0.0.1:8082;  # How do we detect failures?
}
```

**Impact**: Dead containers stay in rotation, causing 12.5% request failures (1/8 backends).

**Fix**: Add health checks with max_fails and fail_timeout

```nginx
upstream conduit_tcp_443 {
    least_conn;
    server 127.0.0.1:8081 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8082 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8083 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8084 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8085 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8086 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8087 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8088 max_fails=3 fail_timeout=30s;
}
```

**Better**: Use Nginx Plus or add external health check script

```bash
#!/bin/bash
# /opt/conduit/health-check.sh
for port in $(seq 8081 8088); do
    if ! nc -zv 127.0.0.1 $port 2>&1 | grep -q succeeded; then
        echo "CRITICAL: Backend $port is DOWN"
        # Alert via Telegram, email, etc.
    fi
done
```

---

### 🔴 BLOCKER #2: Missing Monitoring & Alerting

**Issue**: No metrics collection, no alerts, flying blind.

**What's Missing**:
- Nginx access/error logs not analyzed
- Container crash detection
- Network saturation alerts
- OOM killer monitoring
- Connection queue depth tracking

**Fix**: Implement basic monitoring stack

```bash
# Add to deployment script
setup_monitoring() {
    # 1. Enable Nginx logging
    mkdir -p /var/log/nginx
    cat >> /etc/nginx/nginx.conf << 'EOF'
stream {
    log_format proxy '$remote_addr [$time_local] '
                     '$protocol $status $bytes_sent $bytes_received '
                     '$session_time "$upstream_addr" '
                     '"$upstream_bytes_sent" "$upstream_bytes_received" "$upstream_connect_time"';
    
    access_log /var/log/nginx/stream-access.log proxy;
    error_log /var/log/nginx/stream-error.log warn;
}
EOF

    # 2. Setup logrotate for Nginx
    cat > /etc/logrotate.d/nginx-stream << 'EOF'
/var/log/nginx/stream-*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 nginx adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 `cat /var/run/nginx.pid`
    endscript
}
EOF

    # 3. Add container monitoring cron
    cat > /opt/conduit/monitor-health.sh << 'EOF'
#!/bin/bash
# Monitor containers and alert on issues

ALERT_THRESHOLD_CPU=90
ALERT_THRESHOLD_RAM=85

# Check container health
for i in $(seq 1 8); do
    cname="conduit-${i}"
    
    # Check if running
    if ! docker ps | grep -q "$cname"; then
        echo "ALERT: $cname is not running!" | logger -t conduit-monitor
        # Send Telegram alert if configured
        [ -f /opt/conduit/telegram-alert.sh ] && /opt/conduit/telegram-alert.sh "$cname DOWN"
    fi
    
    # Check resource usage
    stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" "$cname" 2>/dev/null)
    cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
    mem=$(echo "$stats" | awk '{print $2}' | tr -d '%')
    
    if (( $(echo "$cpu > $ALERT_THRESHOLD_CPU" | bc -l) )); then
        echo "WARNING: $cname CPU at ${cpu}%" | logger -t conduit-monitor
    fi
    
    if (( $(echo "$mem > $ALERT_THRESHOLD_RAM" | bc -l) )); then
        echo "WARNING: $cname RAM at ${mem}%" | logger -t conduit-monitor
    fi
done

# Check Nginx
if ! systemctl is-active --quiet nginx; then
    echo "CRITICAL: Nginx is down!" | logger -t conduit-monitor
    systemctl restart nginx
fi

# Check for OOM events (last 5 minutes)
if dmesg -T | tail -100 | grep -i "out of memory.*conduit"; then
    echo "CRITICAL: OOM killer hit conduit containers!" | logger -t conduit-monitor
fi
EOF
    chmod +x /opt/conduit/monitor-health.sh
    
    # Add to crontab (every 5 minutes)
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/conduit/monitor-health.sh") | crontab -
}
```

---

### 🔴 BLOCKER #3: No Graceful Degradation

**Issue**: When containers fail, no automatic recovery or scaling down.

**Scenario**: 2 containers crash at peak load
- Current: 6 containers × 250 = 1,500 capacity (you have 2,000 users) → **500 users dropped**
- Better: Automatically increase `--max-clients` on remaining containers

**Fix**: Implement auto-scaling logic

```bash
auto_scale_on_failure() {
    local running_count=$(docker ps | grep -c "conduit-")
    local total_capacity=$((running_count * 250))
    local current_users=$(get_total_connected_users)
    
    if [ "$current_users" -gt "$total_capacity" ]; then
        local new_max=$(( (current_users / running_count) + 50 ))
        
        # Don't exceed RAM limits
        if [ "$new_max" -gt 350 ]; then
            new_max=350
        fi
        
        echo "Auto-scaling: Setting max-clients to $new_max per container"
        
        for i in $(seq 1 8); do
            local cname="conduit-${i}"
            if docker ps | grep -q "$cname"; then
                # Would need to restart containers with new limit
                # This is where you'd trigger the recreate logic
                echo "Would scale $cname to $new_max clients"
            fi
        done
    fi
}
```

---

### 🔴 BLOCKER #4: Insufficient Logging

**Issue**: Can't debug production issues without proper logging.

**Missing**:
- Nginx upstream selection logs
- Container startup/crash logs with timestamps
- Connection failure tracking
- Performance metrics history

**Fix**: Centralize logging

```bash
setup_logging() {
    # 1. Configure Docker to use json-file with better limits
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5",
    "compress": "true",
    "labels": "production",
    "env": "os,customer"
  }
}
EOF
    systemctl restart docker
    
    # 2. Setup centralized log aggregation
    # For now, just rsyslog local collection
    cat > /etc/rsyslog.d/30-conduit.conf << 'EOF'
# Conduit application logs
:programname, isequal, "conduit" /var/log/conduit/application.log
:programname, isequal, "conduit-monitor" /var/log/conduit/monitoring.log
& stop
EOF
    
    mkdir -p /var/log/conduit
    systemctl restart rsyslog
}
```

---

## 2. Performance & Reliability Concerns

### ⚠️ CONCERN #1: Network Bottleneck Not Addressed

**Issue**: 1Gbps NIC will saturate before RAM at 3 Mbps/client.

**Math Check**:
```
2,000 clients × 3 Mbps × 50% active = 3,000 Mbps theoretical
Practical sustained: ~800 Mbps (burst to 1Gbps)

At 800 Mbps sustained:
  800 / 3 / 0.5 = 533 active clients max
  533 / 0.5 = 1,066 total clients sustainable

Current config: 8 × 250 = 2,000 clients
OVER-PROVISIONED by 88%
```

**Fix**: Two options

**Option A**: Reduce bandwidth expectations
```bash
BANDWIDTH=2  # More realistic for shared 1Gbps
# 2,000 clients × 2 Mbps × 0.5 = 2,000 Mbps theoretical
# Practical: 600-700 Mbps sustained
```

**Option B**: Implement QoS/rate limiting
```bash
# Add tc (traffic control) for bandwidth shaping
tc qdisc add dev eth0 root tbf rate 800mbit burst 32kbit latency 50ms
```

**Recommendation**: Use bandwidth=2, monitor with `iftop`, alert at 700 Mbps.

---

### ⚠️ CONCERN #2: Single Point of Failure (Nginx)

**Issue**: If Nginx crashes, entire service is down.

**Current Architecture**: Nginx → 8 backends  
**Problem**: Nginx failure = total outage  

**Mitigation Strategies**:

1. **Nginx Auto-Restart** (basic, already have)
```bash
systemctl enable nginx  # Already in plan
```

2. **Keepalived for Nginx HA** (advanced, overkill for single-server)
```bash
# Would need second server with floating IP
# Not practical for 4GB VPS
```

3. **Multiple Nginx Workers** (already have)
```nginx
worker_processes 2;  # Already in plan, good
```

4. **Nginx Monitoring & Auto-Restart**
```bash
#!/bin/bash
# /opt/conduit/nginx-watchdog.sh
if ! systemctl is-active --quiet nginx; then
    echo "Nginx down, restarting..." | logger -t nginx-watchdog
    systemctl restart nginx
    
    # Alert
    curl -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=CRITICAL: Nginx crashed and was auto-restarted" \
        2>/dev/null &
fi
```

**Add to crontab**: `* * * * * /opt/conduit/nginx-watchdog.sh`

---

### ⚠️ CONCERN #3: No Connection Draining on Container Restart

**Issue**: Restarting containers drops active connections.

**Current Behavior**:
```bash
docker stop conduit-1  # Sends SIGTERM, waits 10s, SIGKILL
# All 250 clients on conduit-1: DISCONNECTED
```

**Fix**: Implement graceful shutdown

```bash
graceful_restart_container() {
    local cname=$1
    
    # 1. Remove from Nginx upstream (would need dynamic reconfiguration)
    # For now, we rely on Nginx's max_fails detection
    
    # 2. Give container time to close connections
    docker stop -t 60 "$cname"  # Wait 60s before SIGKILL
    
    # 3. Wait for connections to drain
    sleep 10
    
    # 4. Start new container
    run_conduit_container $(echo "$cname" | sed 's/conduit-//')
    
    # 5. Verify healthy
    sleep 5
    if docker ps | grep -q "$cname"; then
        echo "✓ $cname restarted successfully"
    else
        echo "✗ $cname failed to restart"
        # Rollback?
    fi
}
```

---

### ⚠️ CONCERN #4: Nginx Stream Module Limitations

**Issue**: Nginx stream module is basic compared to HAProxy.

**Missing Features**:
- Active health checks (requires Nginx Plus $$$)
- Connection queue visibility
- Real-time backend metrics
- Weighted load balancing adjustments
- Circuit breaking

**Alternative**: HAProxy

```haproxy
# /etc/haproxy/haproxy.cfg (if you switch)
global
    maxconn 20000
    
defaults
    mode tcp
    timeout connect 5s
    timeout client 300s
    timeout server 300s
    
frontend conduit_tcp
    bind :443,:5566
    default_backend conduit_backends
    
frontend conduit_udp
    bind :5566 udp
    default_backend conduit_backends_udp
    
backend conduit_backends
    balance leastconn
    option tcp-check
    server conduit-1 127.0.0.1:8081 check inter 5s fall 3 rise 2
    server conduit-2 127.0.0.1:8082 check inter 5s fall 3 rise 2
    server conduit-3 127.0.0.1:8083 check inter 5s fall 3 rise 2
    server conduit-4 127.0.0.1:8084 check inter 5s fall 3 rise 2
    server conduit-5 127.0.0.1:8085 check inter 5s fall 3 rise 2
    server conduit-6 127.0.0.1:8086 check inter 5s fall 3 rise 2
    server conduit-7 127.0.0.1:8087 check inter 5s fall 3 rise 2
    server conduit-8 127.0.0.1:8088 check inter 5s fall 3 rise 2
    
backend conduit_backends_udp
    balance source  # IP hash for UDP session affinity
    server conduit-1 127.0.0.1:8081
    # ... etc
```

**Decision**: Stick with Nginx for simplicity, but document HAProxy as alternative.

---

## 3. Security Hardening

### 🔒 SECURITY #1: Nginx Running as Root

**Issue**: Default Nginx stream config might run as root.

**Fix**: Ensure Nginx runs as nginx user

```nginx
# /etc/nginx/nginx.conf
user nginx;  # ✅ Already in plan

# Also verify
events {
    worker_processes 2;
    use epoll;
}
```

**Verify**:
```bash
ps aux | grep nginx
# Should show: nginx: master process (root) OK
#              nginx: worker process (nginx) OK
```

---

### 🔒 SECURITY #2: Docker Containers as Root

**Issue**: Psiphon Conduit runs as uid 1000 (non-root), but no explicit user set.

**Current**:
```bash
docker run -d --name conduit-1 \
    ghcr.io/ssmirr/conduit/conduit:latest
# Runs as whatever the image defines (uid 1000)
```

**Hardened**:
```bash
docker run -d --name conduit-1 \
    --user 1000:1000 \
    --read-only \  # Make filesystem read-only
    --tmpfs /tmp:rw,noexec,nosuid,size=100m \
    --security-opt no-new-privileges \
    ghcr.io/ssmirr/conduit/conduit:latest
```

**Issue**: `--read-only` might break conduit_key.json generation.

**Better Approach**:
```bash
# Allow writes only to /home/conduit/data (the volume)
docker run -d --name conduit-1 \
    --user 1000:1000 \
    --security-opt no-new-privileges \
    -v conduit-data-1:/home/conduit/data:rw \
    ghcr.io/ssmirr/conduit/conduit:latest
```

---

### 🔒 SECURITY #3: No Rate Limiting

**Issue**: DDoS attacks can exhaust connection limits.

**Fix**: Add Nginx rate limiting

```nginx
stream {
    # Limit new connections per IP
    limit_conn_zone $binary_remote_addr zone=addr:10m;
    
    server {
        listen 443 reuseport;
        limit_conn addr 10;  # Max 10 concurrent connections per IP
        proxy_pass conduit_tcp_443;
    }
}
```

**Tuning**: 10 connections might be too low for legitimate users.  
**Better**: 50 connections per IP, log when exceeded.

---

### 🔒 SECURITY #4: Exposed Backend Ports

**Issue**: Backend ports on 127.0.0.1:8081-8088 are localhost-only. Good!

**Verification**:
```bash
# After deployment, verify
netstat -tuln | grep 808
# Should show: 127.0.0.1:8081-8088, NOT 0.0.0.0:8081
```

**If exposed on 0.0.0.0** (BAD):
```bash
# Add firewall rules
ufw deny 8081:8088/tcp
ufw deny 8081:8088/udp
```

---

## 4. Operational Runbooks

### 📋 RUNBOOK #1: Container Crash Recovery

**Symptoms**: Dashboard shows fewer than 8 containers running.

**Investigation**:
```bash
# 1. Check which containers are down
docker ps -a | grep conduit

# 2. Check crash logs
docker logs conduit-X | tail -50

# 3. Check for OOM
dmesg -T | grep -i "conduit.*oom"

# 4. Check resource usage
free -m
docker stats --no-stream
```

**Recovery**:
```bash
# Option A: Restart crashed container
docker start conduit-X

# Option B: Recreate if corrupted
docker rm -f conduit-X
/usr/local/bin/conduit restart  # Uses run_conduit logic

# Option C: Emergency scale down
# If RAM is exhausted, reduce container count
CONTAINER_COUNT=6
save_settings
conduit restart
```

---

### 📋 RUNBOOK #2: Nginx Crash Recovery

**Symptoms**: All connections fail, port 443/5566 not listening.

**Investigation**:
```bash
# 1. Check Nginx status
systemctl status nginx
journalctl -u nginx -n 50

# 2. Test config
nginx -t

# 3. Check if ports are bound
netstat -tuln | grep -E ':(443|5566)'

# 4. Check for port conflicts
lsof -i :443
```

**Recovery**:
```bash
# Option A: Restart Nginx
systemctl restart nginx

# Option B: Regenerate config if corrupted
generate_nginx_conf 8
nginx -t
systemctl reload nginx

# Option C: Fallback to single container
# Emergency mode: bypass Nginx, expose one container directly
docker rm -f conduit-1
docker run -d --name conduit-1 \
    --network host \  # Temporary bypass
    -v conduit-data-1:/home/conduit/data \
    ghcr.io/ssmirr/conduit/conduit:latest \
    start --max-clients 1000 --bandwidth 3
```

---

### 📋 RUNBOOK #3: Network Saturation

**Symptoms**: `iftop` shows 900+ Mbps, packet loss, slow connections.

**Investigation**:
```bash
# 1. Check current bandwidth
iftop -i eth0 -t -s 10  # 10 second average

# 2. Identify top talkers
nethogs eth0

# 3. Check container-level bandwidth
docker stats --format "table {{.Name}}\t{{.NetIO}}"

# 4. Check for specific IPs abusing bandwidth
tcpdump -i eth0 -nn | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head
```

**Mitigation**:
```bash
# Option A: Reduce bandwidth per client
# Update settings.conf and restart
BANDWIDTH=2
conduit settings  # Interactive prompt

# Option B: Reduce client count
CONTAINER_COUNT=6
MAX_CLIENTS=200
conduit restart

# Option C: Block abusive IPs
# If single IP consuming >100 Mbps
ufw deny from 1.2.3.4
```

---

### 📋 RUNBOOK #4: OOM Killer Events

**Symptoms**: Containers randomly crash, `dmesg` shows OOM.

**Investigation**:
```bash
# 1. Check OOM logs
dmesg -T | grep -i "out of memory"
journalctl -k | grep -i "killed process"

# 2. Identify memory pressure
free -m
cat /proc/meminfo | grep -i available

# 3. Check swap usage
swapon --show
vmstat 1 5

# 4. Identify memory hogs
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}" | sort -k3 -rn
```

**Recovery**:
```bash
# Option A: Emergency container reduction
CONTAINER_COUNT=6  # From 8
conduit restart

# Option B: Reduce clients per container
MAX_CLIENTS=200  # From 250
conduit settings

# Option C: Add swap (NOT RECOMMENDED, but emergency)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
# Add to /etc/fstab for persistence

# Option D: Upgrade server (best long-term fix)
# Move to 8GB RAM VPS
```

---

## 5. Deployment Best Practices

### ✅ PRE-DEPLOYMENT CHECKLIST

```bash
#!/bin/bash
# pre-deployment-check.sh

echo "=== Pre-Deployment Checklist ==="

# 1. System Requirements
echo -n "Checking RAM... "
ram_mb=$(free -m | awk '/^Mem:/{print $2}')
if [ "$ram_mb" -lt 3900 ]; then
    echo "FAIL: Need 4GB+ RAM, have ${ram_mb}MB"
    exit 1
fi
echo "OK (${ram_mb}MB)"

# 2. Disk Space
echo -n "Checking disk space... "
disk_free=$(df / | awk '/\/$/{print $4}')
if [ "$disk_free" -lt 10000000 ]; then
    echo "FAIL: Need 10GB+ free, have $(($disk_free/1000000))GB"
    exit 1
fi
echo "OK"

# 3. Docker Running
echo -n "Checking Docker... "
if ! systemctl is-active --quiet docker; then
    echo "FAIL: Docker not running"
    exit 1
fi
echo "OK"

# 4. Ports Available
echo -n "Checking ports 443, 5566... "
if netstat -tuln | grep -E ':(443|5566) ' | grep -q LISTEN; then
    echo "FAIL: Ports already in use"
    netstat -tuln | grep -E ':(443|5566) '
    exit 1
fi
echo "OK"

# 5. Kernel Parameters
echo -n "Checking kernel tuning... "
somaxconn=$(sysctl -n net.core.somaxconn)
if [ "$somaxconn" -lt 8192 ]; then
    echo "WARN: somaxconn=$somaxconn (should be 8192+)"
fi
echo "OK"

# 6. Nginx Installed
echo -n "Checking Nginx... "
if ! command -v nginx &>/dev/null; then
    echo "FAIL: Nginx not installed"
    exit 1
fi
echo "OK ($(nginx -v 2>&1 | awk '{print $3}'))"

# 7. Backup of Current Setup
echo -n "Checking for backup... "
if [ -f /opt/conduit/settings.conf.pre-v2 ]; then
    echo "OK (backup exists)"
else
    echo "WARN: No pre-v2 backup found"
fi

echo ""
echo "=== Checklist Complete ==="
```

---

### ✅ STAGED ROLLOUT PLAN

**Phase 1: Single Container Test** (Day 1)
```bash
CONTAINER_COUNT=1
MAX_CLIENTS=250
# Deploy, monitor for 24 hours
# Watch: RAM usage, CPU, container stability
```

**Phase 2: Half Capacity** (Day 2-3)
```bash
CONTAINER_COUNT=4
MAX_CLIENTS=250
# Deploy, monitor for 48 hours
# Watch: Nginx load distribution, no single backend overload
```

**Phase 3: Full Capacity** (Day 4-7)
```bash
CONTAINER_COUNT=8
MAX_CLIENTS=250
# Deploy, monitor for 1 week
# Watch: Network saturation, OOM events, sustained load
```

**Phase 4: Gradual Client Increase** (Week 2+)
```bash
# Week 2: 1,000 clients
# Week 3: 1,500 clients  
# Week 4: 2,000 clients (target)
# Monitor each increment for 3-5 days before increasing
```

---

### ✅ ROLLBACK PROCEDURE

**Automated Rollback Script**:
```bash
#!/bin/bash
# /opt/conduit/rollback-to-v1.sh

set -e

echo "=== ROLLING BACK TO V1.X ==="

# 1. Stop Nginx
systemctl stop nginx
systemctl disable nginx

# 2. Stop all v2.0 containers
for i in $(seq 1 8); do
    docker stop conduit-${i} 2>/dev/null || true
    docker rm conduit-${i} 2>/dev/null || true
done

# 3. Restore v1.x settings
if [ -f /opt/conduit/settings.conf.pre-v2 ]; then
    cp /opt/conduit/settings.conf.pre-v2 /opt/conduit/settings.conf
    source /opt/conduit/settings.conf
fi

# 4. Revert to host networking (v1.x style)
for i in $(seq 1 ${CONTAINER_COUNT:-2}); do
    local cname="conduit"
    local vname="conduit-data"
    [ "$i" -gt 1 ] && cname="conduit-${i}" && vname="conduit-data-${i}"
    
    docker run -d \
        --name "$cname" \
        --restart unless-stopped \
        --network host \
        -v "${vname}:/home/conduit/data" \
        ghcr.io/ssmirr/conduit/conduit:latest \
        start --max-clients ${MAX_CLIENTS:-200} --bandwidth ${BANDWIDTH:-5}
done

# 5. Restart tracker with old config
systemctl restart conduit-tracker

echo "=== Rollback Complete ==="
echo "V1.X containers: $(docker ps | grep -c conduit)"
```

---

## 6. Testing & Validation

### 🧪 LOAD TEST PLAN

```bash
#!/bin/bash
# load-test.sh

echo "=== Conduit Load Test ==="

# Test 1: Single Container Baseline
echo "Test 1: Single container, 100 clients"
CONTAINER_COUNT=1
conduit restart
sleep 30
# Connect 100 Psiphon clients
# Expected: <100 MB RAM, <20% CPU

# Test 2: Multiple Containers, Light Load
echo "Test 2: 4 containers, 400 clients total"
CONTAINER_COUNT=4
conduit restart
sleep 30
# Connect 400 Psiphon clients (100 per container)
# Expected: Even distribution, <500 MB RAM total

# Test 3: Full Capacity, Heavy Load
echo "Test 3: 8 containers, 2000 clients"
CONTAINER_COUNT=8
conduit restart
sleep 30
# Connect 2000 Psiphon clients
# Expected: <3.5 GB RAM, <80% CPU, even distribution

# Test 4: Failure Simulation
echo "Test 4: Kill 2 containers, verify failover"
docker stop conduit-1 conduit-2
sleep 10
# Verify: Clients reconnect to remaining 6 containers
# Expected: Nginx routes new connections to healthy backends

# Test 5: Network Saturation
echo "Test 5: Push bandwidth to limits"
# Generate 800 Mbps traffic through Conduit
# Expected: No packet loss, latency <50ms

echo "=== Load Test Complete ==="
```

---

### 🧪 CHAOS TESTING

```bash
#!/bin/bash
# chaos-test.sh - Simulating production failures

# Chaos 1: Random Container Kills
for i in {1..10}; do
    random_container=$((RANDOM % 8 + 1))
    echo "Killing conduit-${random_container}..."
    docker kill conduit-${random_container}
    sleep 60  # Give 1 minute to recover
    docker start conduit-${random_container}
done

# Chaos 2: Nginx Restart During Load
systemctl restart nginx

# Chaos 3: Network Disruption
tc qdisc add dev eth0 root netem loss 10%  # 10% packet loss
sleep 300  # 5 minutes
tc qdisc del dev eth0 root

# Chaos 4: Memory Pressure
stress-ng --vm 2 --vm-bytes 1G --timeout 60s

# Chaos 5: CPU Spike
stress-ng --cpu 4 --timeout 30s

echo "Chaos tests complete. Check monitoring for recovery."
```

---

## 7. Final Recommendations

### ✅ APPROVED FOR STAGING

**Deploy to staging with these modifications**:

1. **Add Nginx health checks**:
   ```nginx
   server 127.0.0.1:8081 max_fails=3 fail_timeout=30s;
   ```

2. **Implement basic monitoring**:
   - Health check cron (every 5 min)
   - Nginx watchdog (every 1 min)
   - OOM event alerts

3. **Add logging**:
   - Nginx stream access/error logs
   - Container stdout → syslog
   - Centralized in /var/log/conduit/

4. **Create operational runbooks**:
   - Container crash recovery
   - Nginx failover
   - Network saturation mitigation
   - OOM recovery

5. **Test rollback procedure**:
   - Verify can rollback to v1.x in <5 minutes
   - Test with data preservation

### ⏸️ HOLD FOR PRODUCTION

**Do NOT deploy to production until**:

1. ✅ Staged rollout plan executed (1 → 4 → 8 containers over 1 week)
2. ✅ Load testing completed with 2,000 concurrent users
3. ✅ Chaos tests pass with <1% error rate
4. ✅ Monitoring/alerting proven functional
5. ✅ Rollback procedure tested and documented
6. ✅ On-call engineer trained on runbooks

### 📊 PRODUCTION READINESS SCORECARD

| Category | Score | Status |
|----------|-------|--------|
| **Architecture** | 9/10 | ✅ GOOD |
| **Psiphon Compliance** | 10/10 | ✅ EXCELLENT |
| **Resource Tuning** | 8/10 | ✅ GOOD |
| **Monitoring** | 3/10 | ❌ NEEDS WORK |
| **Logging** | 4/10 | ⚠️ BASIC |
| **Operational Runbooks** | 2/10 | ❌ MISSING |
| **Disaster Recovery** | 5/10 | ⚠️ MINIMAL |
| **Security Hardening** | 6/10 | ⚠️ ADEQUATE |
| **Testing** | 4/10 | ⚠️ PLANNED |
| **Documentation** | 8/10 | ✅ GOOD |
| **OVERALL** | **6.0/10** | ⚠️ **NOT PROD READY** |

---

## 8. Action Items Before Production

### HIGH PRIORITY (Blockers)
- [ ] Add Nginx upstream health checks (`max_fails`, `fail_timeout`)
- [ ] Implement container health monitoring cron job
- [ ] Setup Nginx access/error logging for stream module
- [ ] Create and test rollback-to-v1.sh script
- [ ] Write operational runbooks for common failures
- [ ] Configure Telegram/email alerts for critical issues

### MEDIUM PRIORITY (Recommended)
- [ ] Add rate limiting to Nginx (50 conn/IP)
- [ ] Implement graceful container restart with connection draining
- [ ] Setup log rotation for all Conduit logs
- [ ] Create pre-deployment validation script
- [ ] Document expected RAM/CPU/Network at each client count
- [ ] Add OOM watchdog script

### LOW PRIORITY (Nice to Have)
- [ ] Consider HAProxy instead of Nginx for better health checks
- [ ] Add Prometheus metrics exporter
- [ ] Setup Grafana dashboard for real-time monitoring
- [ ] Implement auto-scaling on container failure
- [ ] Add security hardening (--read-only, --security-opt)

---

## 9. Final Verdict

**ARCHITECTURE: APPROVED ✅**  
**PRODUCTION DEPLOYMENT: HOLD ⏸️**

The architecture is sound and Psiphon-compliant, but **operational readiness is insufficient** for production. You have a solid foundation, but you're missing the operational scaffolding that prevents 3 AM pages.

**Bottom Line**: 
- Deploy to **staging** this week with monitoring additions
- Run **load tests** for 1-2 weeks
- Fix issues discovered during testing
- **Production rollout** in 3-4 weeks with phased approach

**Estimated Time to Production-Ready**: 2-3 weeks of testing + hardening

---

**Reviewed by**: Senior DevOps Engineer  
**Next Review**: After staging deployment and load testing  
**Risk Level**: Medium-High (first deployment) → Low (after testing)  

---

*"Hope is not a strategy. Monitor everything, trust nothing, and always have a rollback plan."*  
— Every DevOps Engineer Ever
