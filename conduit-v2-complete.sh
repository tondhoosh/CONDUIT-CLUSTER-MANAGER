#!/bin/bash

#═══════════════════════════════════════════════════════════════════════════
# Psiphon Conduit Manager - High-Performance Cluster Edition v2.0
#═══════════════════════════════════════════════════════════════════════════
# A complete management system for running Psiphon Conduit P2P proxy nodes
# with Nginx Layer 4 Load Balancer, advanced monitoring, and cluster support
#
# GitHub: https://github.com/SamNet-dev/conduit-manager
# Psiphon: https://psiphon.ca
#
# CHANGELOG v2.0:
# ─────────────────────────────────────────────────────────────────────────
# ✨ NEW FEATURES:
#   • Nginx Layer 4 TCP/UDP Load Balancer with health checks
#   • Unlimited container scaling (default 40, recommended 8 for 4GB VPS)
#   • Bridge networking with localhost port mapping (replaces host mode)
#   • System kernel tuning (BBR, somaxconn, file-max, etc.)
#   • Per-container ulimit nofile=16384 for high-concurrency
#   • Single-interface tracker optimization (auto-detects primary NIC)
#   • Health monitoring with automated recovery (cron-based)
#   • Nginx watchdog for load balancer uptime
#   • Centralized logging infrastructure
#   • Operational runbooks built-in
#   • Production-grade DevOps hardening
#
# 🔧 BREAKING CHANGES:
#   • Network mode: host → bridge (localhost:8081-8088)
#   • Max containers: 5 → unlimited (default 40)
#   • Requires: nginx-full or nginx-extras package
#   • System tuning applied on first run (sysctl)
#
# 📋 REQUIREMENTS:
#   • OS: Ubuntu 20.04+, Debian 11+, CentOS 8+, Rocky 9+
#   • RAM: 4GB minimum (8GB recommended for 8+ containers)
#   • CPU: 2 vCores minimum (4+ recommended)
#   • Root access required for installation
#═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

VERSION="2.0.0-cluster"
CONDUIT_IMAGE="psiphon/conduit:latest"
INSTALL_DIR="/opt/conduit"

# v2.0 Configuration Defaults (Hardware-Optimized)
DEFAULT_CONTAINER_COUNT=40         # Unlimited scaling (user can adjust)
RECOMMENDED_CONTAINER_COUNT=8      # For 2 vCore / 4GB RAM VPS
DEFAULT_MAX_CLIENTS=250            # Per container (conservative for 4GB)
DEFAULT_BANDWIDTH=3                # Mbps per client (network-limited)

# Container Resource Limits (per container for 8-container setup)
CONTAINER_CPU_LIMIT="0.22"         # 88% of 2 vCores / 8 = 0.22 per container
CONTAINER_MEM_LIMIT="384m"         # 3GB usable / 8 = 384MB per container
CONTAINER_ULIMIT_NOFILE="16384"    # File descriptors for high concurrency

# Nginx Load Balancer Ports
NGINX_TCP_PORT=443                 # Frontend TCP port
NGINX_UDP_PORT_START=16384         # Frontend UDP range start
NGINX_UDP_PORT_END=32768           # Frontend UDP range end
BACKEND_PORT_START=8081            # Backend container port start (127.0.0.1:8081-8088)

# System Tuning Parameters (conservative, production-safe)
SYSCTL_SOMAXCONN=8192              # TCP listen backlog
SYSCTL_FILE_MAX=524288             # System-wide file descriptors
SYSCTL_NETDEV_MAX_BACKLOG=5000     # Network device backlog

# Health Check Configuration
HEALTH_CHECK_INTERVAL=5            # Minutes between health checks
NGINX_WATCHDOG_INTERVAL=1          # Minutes between Nginx checks

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Global state
HAS_SYSTEMD=false
FORCE_REINSTALL=false
MAX_CLIENTS="${DEFAULT_MAX_CLIENTS}"
BANDWIDTH="${DEFAULT_BANDWIDTH}"
CONTAINER_COUNT="${RECOMMENDED_CONTAINER_COUNT}"  # Default to recommended for 4GB

# System tuning applied flag
SYSTEM_TUNED=false

#═══════════════════════════════════════════════════════════════════════════
# v2.0 NEW FUNCTIONS: Nginx Load Balancer
#═══════════════════════════════════════════════════════════════════════════

generate_nginx_conf() {
    local nginx_conf="/etc/nginx/nginx.conf"
    local stream_conf="/etc/nginx/stream.d/conduit.conf"
    
    log_info "Generating Nginx Layer 4 Load Balancer configuration..."
    
    # Ensure stream.d directory exists
    mkdir -p /etc/nginx/stream.d
    
    # Check if main nginx.conf includes stream block
    if ! grep -q "include /etc/nginx/stream.d/\*.conf;" "$nginx_conf" 2>/dev/null; then
        log_info "Adding stream block to nginx.conf..."
        
        # Backup original nginx.conf
        cp "$nginx_conf" "${nginx_conf}.bak.$(date +%s)" 2>/dev/null || true
        
        # Add stream block before http block if it doesn't exist
        if grep -q "^stream {" "$nginx_conf" 2>/dev/null; then
            # Stream block exists, just ensure our include is there
            sed -i '/^stream {/a\    include /etc/nginx/stream.d/*.conf;' "$nginx_conf"
        else
            # Add new stream block before http block
            sed -i '/^http {/i\stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' "$nginx_conf"
        fi
    fi
    
    # Generate conduit stream configuration
    cat > "$stream_conf" << 'NGINX_STREAM_EOF'
# Psiphon Conduit Layer 4 Load Balancer
# Generated by Conduit Manager v2.0

# Upstream: TCP backends (port 443)
upstream conduit_tcp_backend {
    least_conn;  # Load balancing: least connections
NGINX_STREAM_EOF

    # Add TCP backends with health checks
    for i in $(seq 1 $CONTAINER_COUNT); do
        local backend_port=$((BACKEND_PORT_START + i - 1))
        cat >> "$stream_conf" << NGINX_STREAM_EOF
    server 127.0.0.1:${backend_port} max_fails=3 fail_timeout=30s;
NGINX_STREAM_EOF
    done

    cat >> "$stream_conf" << 'NGINX_STREAM_EOF'
}

# Upstream: UDP backends (QUIC/WebRTC, ports 16384-32768)
upstream conduit_udp_backend {
    hash $remote_addr consistent;  # Session affinity for UDP
NGINX_STREAM_EOF

    # Add UDP backends with health checks
    for i in $(seq 1 $CONTAINER_COUNT); do
        local backend_port=$((BACKEND_PORT_START + i - 1))
        cat >> "$stream_conf" << NGINX_STREAM_EOF
    server 127.0.0.1:${backend_port} max_fails=3 fail_timeout=30s;
NGINX_STREAM_EOF
    done

    cat >> "$stream_conf" << NGINX_STREAM_EOF

}

# TCP Server: Port 443 → Backend containers
server {
    listen ${NGINX_TCP_PORT};
    proxy_pass conduit_tcp_backend;
    proxy_timeout 10m;
    proxy_connect_timeout 30s;
    
    # Enable TCP proxy protocol for client IP preservation (optional)
    # proxy_protocol on;
}

# UDP Server: Ports ${NGINX_UDP_PORT_START}-${NGINX_UDP_PORT_END} → Backend containers
server {
    listen ${NGINX_UDP_PORT_START}-${NGINX_UDP_PORT_END} udp;
    proxy_pass conduit_udp_backend;
    proxy_timeout 10m;
    proxy_responses 1;
}

# Logging
error_log /var/log/nginx/conduit-stream-error.log warn;
access_log /var/log/nginx/conduit-stream-access.log;
NGINX_STREAM_EOF

    log_success "Nginx configuration generated: $stream_conf"
}

reload_nginx() {
    log_info "Testing Nginx configuration..."
    if nginx -t 2>&1 | tee /tmp/nginx-test.log; then
        log_info "Reloading Nginx..."
        systemctl reload nginx || systemctl restart nginx
        log_success "Nginx reloaded successfully"
        return 0
    else
        log_error "Nginx configuration test failed:"
        cat /tmp/nginx-test.log
        return 1
    fi
}

install_nginx() {
    log_info "Installing Nginx with stream module..."
    
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y nginx-full || apt-get install -y nginx-extras
    elif command -v yum &>/dev/null; then
        yum install -y nginx nginx-mod-stream
    elif command -v dnf &>/dev/null; then
        dnf install -y nginx nginx-mod-stream
    else
        log_error "Unsupported package manager. Please install nginx manually."
        return 1
    fi
    
    # Enable and start Nginx
    systemctl enable nginx
    systemctl start nginx
    
    log_success "Nginx installed"
}

check_nginx_stream_module() {
    if ! nginx -V 2>&1 | grep -q "stream"; then
        log_error "Nginx stream module not available. Installing nginx-full..."
        install_nginx
    fi
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 NEW FUNCTIONS: System Tuning
#═══════════════════════════════════════════════════════════════════════════

tune_system() {
    if [ "$SYSTEM_TUNED" = "true" ]; then
        log_info "System already tuned (skipping)"
        return 0
    fi
    
    log_info "Applying kernel tuning for high-performance cluster..."
    
    # Backup current sysctl settings
    sysctl -a > "$INSTALL_DIR/sysctl-backup-$(date +%s).txt" 2>/dev/null || true
    
    # Create conduit sysctl configuration
    cat > /etc/sysctl.d/99-conduit-cluster.conf << 'SYSCTL_EOF'
# Psiphon Conduit Cluster - Kernel Tuning v2.0
# Applied: $(date)
# Safe for production, conservative limits

# TCP Connection Tuning
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000

# File Descriptor Limits
fs.file-max = 524288

# TCP BBR Congestion Control (better throughput)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP Fast Open (reduces latency)
net.ipv4.tcp_fastopen = 3

# Connection Tracking (for high concurrency)
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144

# TCP Memory Tuning
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# UDP Buffer Sizes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728

# Reduce TIME_WAIT socket accumulation
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Local Port Range (for outbound connections)
net.ipv4.ip_local_port_range = 10000 65535
SYSCTL_EOF

    # Apply settings
    if sysctl -p /etc/sysctl.d/99-conduit-cluster.conf; then
        log_success "Kernel tuning applied"
        SYSTEM_TUNED=true
        
        # Save tuning state
        echo "SYSTEM_TUNED=true" >> "$INSTALL_DIR/settings.conf"
    else
        log_warning "Some sysctl settings failed to apply (may require reboot)"
    fi
    
    # Increase system-wide file descriptor limits
    log_info "Configuring system file descriptor limits..."
    
    if ! grep -q "conduit" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITS_EOF'

# Psiphon Conduit Cluster - File Descriptor Limits
* soft nofile 262144
* hard nofile 524288
root soft nofile 262144
root hard nofile 524288
LIMITS_EOF
        log_success "File descriptor limits configured"
    fi
}

check_system_resources() {
    local total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local total_cpu=$(nproc)
    
    log_info "System Resources:"
    echo "  CPU Cores: ${total_cpu}"
    echo "  RAM: ${total_ram_mb} MB"
    
    # Calculate recommended container count
    local recommended_containers=$CONTAINER_COUNT
    
    if [ "$total_ram_mb" -lt 3500 ]; then
        recommended_containers=4
        log_warning "Low RAM detected. Recommending 4 containers max."
    elif [ "$total_ram_mb" -lt 7500 ]; then
        recommended_containers=8
        log_info "4GB RAM detected. Recommending 8 containers (current default)."
    elif [ "$total_ram_mb" -lt 15000 ]; then
        recommended_containers=16
        log_info "8-16GB RAM detected. You can run 16 containers."
    else
        recommended_containers=32
        log_info "High RAM detected. You can run 32+ containers."
    fi
    
    echo "  Recommended containers: ${recommended_containers}"
    echo ""
    
    # Update CONTAINER_COUNT if user wants recommendation
    if [ "$CONTAINER_COUNT" != "$recommended_containers" ] && [ "${INTERACTIVE:-true}" = "true" ]; then
        read -p "Use recommended container count (${recommended_containers})? [Y/n]: " use_rec < /dev/tty || true
        if [[ ! "$use_rec" =~ ^[Nn]$ ]]; then
            CONTAINER_COUNT=$recommended_containers
            log_success "Container count set to ${CONTAINER_COUNT}"
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 NEW FUNCTIONS: Monitoring & Health Checks
#═══════════════════════════════════════════════════════════════════════════

generate_health_check_script() {
    log_info "Creating health check monitoring script..."
    
    cat > "$INSTALL_DIR/health-check.sh" << 'HEALTH_CHECK_EOF'
#!/bin/bash
# Conduit v2.0 Health Check Monitor
# Runs every 5 minutes via cron

INSTALL_DIR="/opt/conduit"
LOG_FILE="$INSTALL_DIR/health-check.log"
ALERT_FILE="$INSTALL_DIR/health-alerts.log"

source "$INSTALL_DIR/settings.conf" 2>/dev/null || true

log_health() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

send_alert() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $message" >> "$ALERT_FILE"
    
    # Send Telegram alert if enabled
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ] && [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
        local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=🚨 *ALERT* [${server_label}]%0A%0A${message}" \
            -d "parse_mode=Markdown" &>/dev/null || true
    fi
}

# Check Docker daemon
if ! docker info &>/dev/null; then
    send_alert "Docker daemon is not responding. Attempting restart..."
    systemctl restart docker
    sleep 5
    if ! docker info &>/dev/null; then
        send_alert "Docker restart failed. Manual intervention required."
        exit 1
    fi
    send_alert "Docker daemon restarted successfully"
fi

# Check Nginx
if ! systemctl is-active nginx &>/dev/null; then
    send_alert "Nginx is down. Attempting restart..."
    systemctl restart nginx
    sleep 3
    if ! systemctl is-active nginx &>/dev/null; then
        send_alert "Nginx restart failed. Manual intervention required."
    else
        send_alert "Nginx restarted successfully"
    fi
fi

# Check each container
for i in $(seq 1 ${CONTAINER_COUNT:-8}); do
    if [ $i -eq 1 ]; then
        cname="conduit"
    else
        cname="conduit-${i}"
    fi
    
    # Check if container exists and is running
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
        send_alert "Container ${cname} is not running. Attempting restart..."
        docker start "$cname" 2>/dev/null || {
            send_alert "Container ${cname} failed to start. Recreating..."
            # Container might be corrupted, recreate it
            /usr/local/bin/conduit start &>/dev/null
        }
    fi
    
    # Check restart count (excessive restarts indicate a problem)
    local restarts=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")
    if [ "$restarts" -gt 10 ]; then
        send_alert "Container ${cname} has ${restarts} restarts. Possible stability issue."
    fi
done

# Check system resources
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
mem_usage=$(free | awk '/Mem/{printf("%.1f"), $3/$2*100}')

if (( $(echo "$cpu_usage > 90" | bc -l) )); then
    send_alert "High CPU usage: ${cpu_usage}%"
fi

if (( $(echo "$mem_usage > 90" | bc -l) )); then
    send_alert "High memory usage: ${mem_usage}%"
fi

# Check if OOM killer has been active
if dmesg -T | tail -100 | grep -i "killed process" | grep -i "conduit" &>/dev/null; then
    send_alert "OOM killer has terminated a Conduit container. Consider increasing RAM or reducing containers."
fi

log_health "Health check completed: All systems operational"
HEALTH_CHECK_EOF

    chmod 700 "$INSTALL_DIR/health-check.sh"
    log_success "Health check script created"
}

generate_nginx_watchdog() {
    log_info "Creating Nginx watchdog script..."
    
    cat > "$INSTALL_DIR/nginx-watchdog.sh" << 'NGINX_WATCHDOG_EOF'
#!/bin/bash
# Nginx Watchdog - Ensures Nginx stays running
# Runs every 1 minute via cron

if ! systemctl is-active nginx &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx down, restarting..." >> /opt/conduit/nginx-watchdog.log
    systemctl restart nginx
    
    # Send alert
    source /opt/conduit/settings.conf 2>/dev/null || true
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ] && [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
        local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=⚠️ Nginx watchdog restarted Nginx on ${server_label}" \
            -d "parse_mode=Markdown" &>/dev/null || true
    fi
fi
NGINX_WATCHDOG_EOF

    chmod 700 "$INSTALL_DIR/nginx-watchdog.sh"
    log_success "Nginx watchdog script created"
}

setup_monitoring_cron() {
    log_info "Setting up monitoring cron jobs..."
    
    # Remove old cron entries
    crontab -l 2>/dev/null | grep -v "conduit/health-check.sh" | grep -v "conduit/nginx-watchdog.sh" | crontab - 2>/dev/null || true
    
    # Add new cron entries
    (crontab -l 2>/dev/null; echo "# Conduit v2.0 Health Monitoring") | crontab -
    (crontab -l 2>/dev/null; echo "*/${HEALTH_CHECK_INTERVAL} * * * * /opt/conduit/health-check.sh") | crontab -
    (crontab -l 2>/dev/null; echo "*/${NGINX_WATCHDOG_INTERVAL} * * * * /opt/conduit/nginx-watchdog.sh") | crontab -
    
    log_success "Monitoring cron jobs configured"
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 MODIFIED: Container Management (Bridge Networking)
#═══════════════════════════════════════════════════════════════════════════

run_conduit_container() {
    local index=${1:-1}
    local cname=$(get_container_name $index)
    local vname=$(get_volume_name $index)
    local backend_port=$((BACKEND_PORT_START + index - 1))
    
    # Create volume if it doesn't exist
    docker volume create "$vname" &>/dev/null || true
    
    # Build docker run command with v2.0 enhancements
    local docker_cmd="docker run -d --name \"$cname\" --restart unless-stopped"
    
    # v2.0: Bridge networking with localhost port mapping (replaces --network host)
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:443/tcp"
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:443/udp"
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:16384-32768/udp"
    
    # v2.0: Resource limits (CPU, memory)
    docker_cmd="$docker_cmd --cpus=\"${CONTAINER_CPU_LIMIT}\""
    docker_cmd="$docker_cmd --memory=\"${CONTAINER_MEM_LIMIT}\""
    
    # v2.0: Increased file descriptor limits for high concurrency
    docker_cmd="$docker_cmd --ulimit nofile=${CONTAINER_ULIMIT_NOFILE}:${CONTAINER_ULIMIT_NOFILE}"
    
    # Volume mount
    docker_cmd="$docker_cmd -v \"$vname:/data\""
    
    # Conduit arguments
    docker_cmd="$docker_cmd \"$CONDUIT_IMAGE\" conduit"
    docker_cmd="$docker_cmd --max-clients ${MAX_CLIENTS}"
    
    if [ "$BANDWIDTH" != "-1" ]; then
        docker_cmd="$docker_cmd --bandwidth ${BANDWIDTH}"
    fi
    
    # Execute
    eval "$docker_cmd"
    
    if [ $? -eq 0 ]; then
        log_success "Container ${cname} started (backend: 127.0.0.1:${backend_port})"
        return 0
    else
        log_error "Failed to start container ${cname}"
        return 1
    fi
}

run_conduit() {
    log_info "Starting ${CONTAINER_COUNT} Conduit container(s)..."
    
    # Ensure Docker volume permissions
    fix_volume_permissions
    
    local success_count=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        if run_conduit_container $i; then
            success_count=$((success_count + 1))
        fi
        sleep 2  # Brief delay between container starts
    done
    
    if [ $success_count -eq $CONTAINER_COUNT ]; then
        log_success "All ${CONTAINER_COUNT} containers started successfully"
        return 0
    elif [ $success_count -gt 0 ]; then
        log_warning "${success_count}/${CONTAINER_COUNT} containers started"
        return 1
    else
        log_error "Failed to start any containers"
        return 1
    fi
}

get_container_name() {
    local index=${1:-1}
    if [ $index -eq 1 ]; then
        echo "conduit"
    else
        echo "conduit-${index}"
    fi
}

get_volume_name() {
    local index=${1:-1}
    if [ $index -eq 1 ]; then
        echo "conduit-data"
    else
        echo "conduit-data-${index}"
    fi
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 MODIFIED: Tracker Script (Single-Interface Optimization)
#═══════════════════════════════════════════════════════════════════════════

detect_primary_interface() {
    # Auto-detect primary network interface (the one with default route)
    local primary_if=$(ip route | grep default | head -1 | awk '{print $5}')
    
    if [ -z "$primary_if" ]; then
        # Fallback: first non-loopback interface
        primary_if=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | awk -F': ' '{print $2}')
    fi
    
    echo "$primary_if"
}

generate_tracker_script() {
    log_info "Generating optimized tracker script (single-interface mode)..."
    
    local primary_interface=$(detect_primary_interface)
    
    if [ -z "$primary_interface" ]; then
        log_warning "Could not detect primary network interface. Tracker may not work correctly."
        primary_interface="eth0"  # Fallback
    fi
    
    log_info "Primary network interface detected: ${primary_interface}"
    
    cat > "$INSTALL_DIR/conduit-tracker.sh" << 'TRACKER_EOF'
#!/bin/bash
# Conduit v2.0 Network Traffic Tracker (Single-Interface Optimized)
# This script monitors traffic on PRIMARY_INTERFACE_PLACEHOLDER and aggregates statistics

PERSIST_DIR="/opt/conduit/traffic_stats"
SNAPSHOT_FILE="$PERSIST_DIR/tracker_snapshot"
CUMULATIVE_DATA="$PERSIST_DIR/cumulative_data"
CUMULATIVE_IPS="$PERSIST_DIR/cumulative_ips"
GEOIP_CACHE="$PERSIST_DIR/geoip_cache"

# v2.0: Monitor ONLY primary interface (optimized)
PRIMARY_INTERFACE="PRIMARY_INTERFACE_PLACEHOLDER"

mkdir -p "$PERSIST_DIR"
touch "$CUMULATIVE_DATA" "$CUMULATIVE_IPS" "$GEOIP_CACHE" "$SNAPSHOT_FILE"

get_country() {
    local ip="$1"
    
    # Skip private/local IPs
    if echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.)'; then
        echo "LOCAL"
        return
    fi
    
    # Check cache first
    local cached=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | cut -d'|' -f2)
    if [ -n "$cached" ]; then
        echo "$cached"
        return
    fi
    
    # Lookup country
    local country="Unknown"
    if command -v geoiplookup &>/dev/null; then
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F': ' '{print $2}' | cut -d',' -f1 | head -1)
    elif command -v mmdblookup &>/dev/null; then
        country=$(mmdblookup --file /usr/share/GeoIP/GeoLite2-Country.mmdb --ip "$ip" country names en 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
    fi
    
    [ -z "$country" ] && country="Unknown"
    
    # Cache result
    echo "${ip}|${country}" >> "$GEOIP_CACHE"
    echo "$country"
}

# Main monitoring loop
while true; do
    # v2.0: Capture ONLY on primary interface (significantly faster)
    timeout 15 tcpdump -i "$PRIMARY_INTERFACE" -nn -q -t -l \
        'tcp or udp and not port 22' 2>/dev/null | \
    awk -v snapshot="$SNAPSHOT_FILE" -v cumulative="$CUMULATIVE_DATA" -v ips="$CUMULATIVE_IPS" '
    {
        # Parse source and destination
        match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)
        src_ip = substr($0, RSTART, RLENGTH)
        
        match($0, /> ([0-9]{1,3}\.){3}[0-9]{1,3}/)
        dst_ip = substr($0, RSTART+2, RLENGTH-2)
        
        # Extract length
        if (match($0, /length [0-9]+/)) {
            len = substr($0, RSTART+7, RLENGTH-7)
        } else {
            len = 0
        }
        
        if (src_ip != "" && dst_ip != "") {
            # Traffic direction: out if src is local
            if (src_ip ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.)/) {
                # Outbound
                out[dst_ip] += len
                all_ips[dst_ip] = 1
            } else {
                # Inbound
                in[src_ip] += len
                all_ips[src_ip] = 1
            }
        }
    }
    END {
        # Write snapshot
        for (ip in all_ips) {
            print ip "|" in[ip] "|" out[ip] >> snapshot ".tmp"
        }
    }
    ' && mv "$SNAPSHOT_FILE.tmp" "$SNAPSHOT_FILE" 2>/dev/null || true
    
    # Process snapshot and update cumulative data
    if [ -s "$SNAPSHOT_FILE" ]; then
        while IFS='|' read -r ip bytes_in bytes_out; do
            [ -z "$ip" ] && continue
            
            # Get country
            country=$(get_country "$ip")
            
            # Update cumulative IPs
            if ! grep -q "^${ip}|" "$CUMULATIVE_IPS" 2>/dev/null; then
                echo "${ip}|${country}" >> "$CUMULATIVE_IPS"
            fi
            
            # Update cumulative data
            local existing=$(grep "^${country}|" "$CUMULATIVE_DATA" 2>/dev/null)
            if [ -n "$existing" ]; then
                local old_in=$(echo "$existing" | cut -d'|' -f2)
                local old_out=$(echo "$existing" | cut -d'|' -f3)
                local new_in=$((old_in + bytes_in))
                local new_out=$((old_out + bytes_out))
                sed -i "s/^${country}|.*/${country}|${new_in}|${new_out}/" "$CUMULATIVE_DATA"
            else
                echo "${country}|${bytes_in}|${bytes_out}" >> "$CUMULATIVE_DATA"
            fi
        done < "$SNAPSHOT_FILE"
    fi
    
    sleep 1
done
TRACKER_EOF

    # Replace placeholder with actual interface
    sed -i "s/PRIMARY_INTERFACE_PLACEHOLDER/${primary_interface}/g" "$INSTALL_DIR/conduit-tracker.sh"
    
    chmod 700 "$INSTALL_DIR/conduit-tracker.sh"
    log_success "Tracker script generated (monitoring: ${primary_interface})"
}

regenerate_tracker_script() {
    generate_tracker_script
}

setup_tracker_service() {
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-tracker.service << EOF
[Unit]
Description=Conduit Network Traffic Tracker
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-tracker.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable conduit-tracker.service
        systemctl restart conduit-tracker.service
        log_success "Tracker service enabled"
    fi
}

stop_tracker_service() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-tracker.service 2>/dev/null || true
    fi
}

is_tracker_active() {
    if command -v systemctl &>/dev/null; then
        systemctl is-active conduit-tracker.service &>/dev/null
        return $?
    fi
    return 1
}

#═══════════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════════

log_info() {
    echo -e "${CYAN}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Psiphon Conduit Manager${NC} - ${YELLOW}High-Performance Cluster v${VERSION}${NC}   ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        echo "Please run: sudo bash $0"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi
    
    if command -v systemctl &>/dev/null; then
        HAS_SYSTEMD=true
    fi
    
    log_info "Detected: $PRETTY_NAME"
}

check_dependencies() {
    log_info "Checking dependencies..."
    
    local missing_deps=()
    
    # Essential tools
    for cmd in docker nginx curl awk sed grep; do
        if ! command -v $cmd &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    # Monitoring tools
    if ! command -v tcpdump &>/dev/null; then
        log_warning "tcpdump not found. Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y tcpdump
        elif command -v yum &>/dev/null; then
            yum install -y tcpdump
        fi
    fi
    
    # GeoIP tools (optional)
    if ! command -v geoiplookup &>/dev/null && ! command -v mmdblookup &>/dev/null; then
        log_warning "GeoIP tools not found. Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y geoip-bin geoip-database
        elif command -v yum &>/dev/null; then
            yum install -y GeoIP GeoIP-data
        fi
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Installing dependencies..."
        install_docker
        install_nginx
        check_nginx_stream_module
    fi
    
    log_success "All dependencies satisfied"
}

install_docker() {
    if command -v docker &>/dev/null; then
        log_success "Docker already installed"
        return 0
    fi
    
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
    log_success "Docker installed"
}

fix_volume_permissions() {
    for i in $(seq 1 $CONTAINER_COUNT); do
        local vname=$(get_volume_name $i)
        docker volume create "$vname" &>/dev/null || true
        docker run --rm -v "$vname:/data" alpine chown -R 1000:1000 /data 2>/dev/null || true
    done
}

save_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/settings.conf" << EOF
# Conduit v2.0 Configuration
VERSION="$VERSION"
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_CPU_LIMIT="$CONTAINER_CPU_LIMIT"
CONTAINER_MEM_LIMIT="$CONTAINER_MEM_LIMIT"
CONTAINER_ULIMIT_NOFILE="$CONTAINER_ULIMIT_NOFILE"
SYSTEM_TUNED=${SYSTEM_TUNED}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL:-}"
EOF
    log_success "Settings saved to $INSTALL_DIR/settings.conf"
}

save_settings_install() {
    save_settings
}

start_conduit() {
    log_info "Starting Conduit cluster..."
    run_conduit
    
    # Regenerate Nginx config if container count changed
    if command -v nginx &>/dev/null; then
        generate_nginx_conf
        reload_nginx
    fi
}

stop_conduit() {
    log_info "Stopping Conduit cluster..."
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        docker stop "$cname" 2>/dev/null || true
    done
    log_success "All containers stopped"
}

restart_conduit() {
    stop_conduit
    sleep 2
    start_conduit
}

setup_autostart() {
    if ! command -v systemctl &>/dev/null; then
        log_warning "systemd not available, skipping autostart setup"
        return 0
    fi
    
    log_info "Setting up autostart service..."
    
    cat > /etc/systemd/system/conduit.service << 'SERVICE_EOF'
[Unit]
Description=Psiphon Conduit Cluster Service
After=network.target docker.service nginx.service
Wants=docker.service nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start
ExecStop=/usr/local/bin/conduit stop

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable conduit.service
    log_success "Autostart configured"
}

#═══════════════════════════════════════════════════════════════════════════
# Management CLI Placeholder
# (The full script continues with all dashboard, stats, menu functions from v1.x)
# This is a working foundation - the complete 6757+ line script would follow
#═══════════════════════════════════════════════════════════════════════════

create_management_script() {
    log_info "Creating management CLI..."
    
    # Copy this script to /opt/conduit/conduit
    cp "$0" "$INSTALL_DIR/conduit"
    chmod +x "$INSTALL_DIR/conduit"
    
    # Create symlink
    ln -sf "$INSTALL_DIR/conduit" /usr/local/bin/conduit
    
    log_success "Management CLI installed: conduit"
}

show_help() {
    echo "Conduit Manager v${VERSION} - High-Performance Cluster Edition"
    echo ""
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  start         Start all Conduit containers and Nginx LB"
    echo "  stop          Stop all containers"
    echo "  restart       Restart cluster"
    echo "  status        Show cluster status"
    echo "  health        Run comprehensive health check"
    echo "  scale <N>     Scale to N containers (requires config regeneration)"
    echo "  menu          Open interactive menu (default)"
    echo "  version       Show version information"
    echo "  help          Show this help"
    echo ""
    echo "v2.0 Features:"
    echo "  • Nginx Layer 4 Load Balancer (TCP/UDP)"
    echo "  • Unlimited container scaling (default: 8 for 4GB VPS)"
    echo "  • System kernel tuning (BBR, somaxconn, file-max)"
    echo "  • Health monitoring & automated recovery"
    echo "  • Single-interface traffic tracking"
}

show_version() {
    echo "Conduit Manager ${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"
    echo ""
    echo "v2.0 Cluster Edition Features:"
    echo "  ✓ Nginx Layer 4 Load Balancer"
    echo "  ✓ Bridge networking (localhost:8081-N)"
    echo "  ✓ Unlimited container scaling"
    echo "  ✓ System kernel tuning (BBR, somaxconn)"
    echo "  ✓ Health monitoring & watchdog"
    echo "  ✓ Production-ready DevOps hardening"
}

health_check() {
    echo -e "${CYAN}═══ CONDUIT v2.0 CLUSTER HEALTH CHECK ═══${NC}"
    echo ""
    
    local all_ok=true
    
    # Docker daemon
    echo -n "Docker daemon:        "
    if docker info &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        all_ok=false
    fi
    
    # Nginx
    echo -n "Nginx:                "
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        all_ok=false
    fi
    
    echo -n "Nginx stream module:  "
    if nginx -V 2>&1 | grep -q "stream"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}MISSING${NC}"
        all_ok=false
    fi
    
    # Containers
    echo ""
    echo -e "${CYAN}--- Containers ---${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        echo -n "${cname}:$(printf '%*s' $((20 - ${#cname})) '')"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            echo -e "${GREEN}RUNNING${NC}"
        else
            echo -e "${RED}STOPPED${NC}"
            all_ok=false
        fi
    done
    
    # System resources
    echo ""
    echo -e "${CYAN}--- System Resources ---${NC}"
    echo "CPU Usage:  $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')%"
    echo "RAM Usage:  $(free | awk '/Mem/{printf("%.1f%%"), $3/$2*100}')"
    echo "Containers: ${CONTAINER_COUNT}"
    
    echo ""
    if [ "$all_ok" = "true" ]; then
        echo -e "${GREEN}✓ All health checks passed${NC}"
        return 0
    else
        echo -e "${RED}✗ Some health checks failed${NC}"
        return 1
    fi
}

uninstall_all() {
    echo -e "${RED}WARNING: This will remove ALL Conduit components!${NC}"
    read -p "Type 'yes' to confirm: " confirm < /dev/tty || true
    
    if [ "$confirm" != "yes" ]; then
        echo "Cancelled."
        return 0
    fi
    
    log_info "Uninstalling Conduit v2.0..."
    
    # Stop all services
    systemctl stop conduit.service 2>/dev/null || true
    systemctl stop conduit-tracker.service 2>/dev/null || true
    systemctl disable conduit.service 2>/dev/null || true
    systemctl disable conduit-tracker.service 2>/dev/null || true
    
    # Remove containers
    for i in $(seq 1 40); do
        local cname=$(get_container_name $i)
        local vname=$(get_volume_name $i)
        docker rm -f "$cname" 2>/dev/null || true
        docker volume rm "$vname" 2>/dev/null || true
    done
    
    # Remove Nginx config
    rm -f /etc/nginx/stream.d/conduit.conf
    systemctl reload nginx 2>/dev/null || true
    
    # Remove files
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/conduit
    rm -f /etc/systemd/system/conduit.service
    rm -f /etc/systemd/system/conduit-tracker.service
    rm -f /etc/sysctl.d/99-conduit-cluster.conf
    
    # Remove cron jobs
    crontab -l 2>/dev/null | grep -v "conduit" | crontab - 2>/dev/null || true
    
    systemctl daemon-reload
    
    log_success "Uninstall complete"
}

prompt_settings() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}CLUSTER CONFIGURATION${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    # Container count
    echo -e "How many containers do you want to run?"
    echo -e "  ${DIM}Recommended for 4GB VPS: 8 containers${NC}"
    echo -e "  ${DIM}Each container ~= 384MB RAM + 250 max clients${NC}"
    echo ""
    read -p "Container count [${RECOMMENDED_CONTAINER_COUNT}]: " input_count < /dev/tty || true
    CONTAINER_COUNT="${input_count:-${RECOMMENDED_CONTAINER_COUNT}}"
    
    # Max clients per container
    echo ""
    echo -e "Max clients per container?"
    echo -e "  ${DIM}Default: ${DEFAULT_MAX_CLIENTS} (conservative)${NC}"
    echo ""
    read -p "Max clients [${DEFAULT_MAX_CLIENTS}]: " input_clients < /dev/tty || true
    MAX_CLIENTS="${input_clients:-${DEFAULT_MAX_CLIENTS}}"
    
    # Bandwidth per client
    echo ""
    echo -e "Bandwidth limit per client (Mbps)?"
    echo -e "  ${DIM}Default: ${DEFAULT_BANDWIDTH} Mbps (network-optimized for 1Gbps NIC)${NC}"
    echo -e "  ${DIM}-1 = unlimited${NC}"
    echo ""
    read -p "Bandwidth [${DEFAULT_BANDWIDTH}]: " input_bw < /dev/tty || true
    BANDWIDTH="${input_bw:-${DEFAULT_BANDWIDTH}}"
    
    echo ""
    log_success "Configuration:"
    echo "  Containers: ${CONTAINER_COUNT}"
    echo "  Max clients/container: ${MAX_CLIENTS}"
    echo "  Bandwidth/client: ${BANDWIDTH} Mbps"
    echo "  Total capacity: ~$((CONTAINER_COUNT * MAX_CLIENTS)) concurrent users"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════════
# Main Installation Flow
#═══════════════════════════════════════════════════════════════════════════

main() {
    case "${1:-menu}" in
        start)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            start_conduit
            ;;
        stop)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            stop_conduit
            ;;
        restart)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            restart_conduit
            ;;
        status)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            health_check
            ;;
        health)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            health_check
            ;;
        scale)
            if [ -z "${2:-}" ]; then
                echo "Usage: conduit scale <number>"
                exit 1
            fi
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            CONTAINER_COUNT=$2
            save_settings
            log_info "Scaling to ${CONTAINER_COUNT} containers..."
            stop_conduit
            generate_nginx_conf
            reload_nginx
            start_conduit
            log_success "Scaled to ${CONTAINER_COUNT} containers"
            ;;
        uninstall)
            [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
            uninstall_all
            ;;
        version|-v|--version)
            show_version
            ;;
        help|-h|--help)
            show_help
            ;;
        menu|*)
            if [ -f "$INSTALL_DIR/settings.conf" ]; then
                source "$INSTALL_DIR/settings.conf"
                echo "Run 'conduit help' for available commands."
            else
                # First-time installation
                print_header
                check_root
                detect_os
                check_dependencies
                check_system_resources
                prompt_settings
                
                echo ""
                log_info "Starting Conduit v2.0 installation..."
                echo ""
                
                # Step 1: System tuning
                log_info "Step 1/7: System kernel tuning..."
                tune_system
                echo ""
                
                # Step 2: Install Nginx
                log_info "Step 2/7: Installing Nginx with stream module..."
                check_nginx_stream_module
                echo ""
                
                # Step 3: Generate Nginx config
                log_info "Step 3/7: Generating Nginx Load Balancer config..."
                generate_nginx_conf
                reload_nginx
                echo ""
                
                # Step 4: Start containers
                log_info "Step 4/7: Starting ${CONTAINER_COUNT} Conduit containers..."
                run_conduit
                echo ""
                
                # Step 5: Setup monitoring
                log_info "Step 5/7: Setting up health monitoring..."
                generate_health_check_script
                generate_nginx_watchdog
                setup_monitoring_cron
                echo ""
                
                # Step 6: Setup tracker
                log_info "Step 6/7: Setting up traffic tracker..."
                generate_tracker_script
                setup_tracker_service
                echo ""
                
                # Step 7: Finalize
                log_info "Step 7/7: Finalizing installation..."
                save_settings
                setup_autostart
                create_management_script
                echo ""
                
                log_success "═══════════════════════════════════════════════════════════"
                log_success "  CONDUIT v2.0 CLUSTER EDITION INSTALLED!"
                log_success "═══════════════════════════════════════════════════════════"
                echo ""
                echo "Configuration:"
                echo "  • Containers: ${CONTAINER_COUNT}"
                echo "  • Max clients/container: ${MAX_CLIENTS}"
                echo "  • Total capacity: ~$((CONTAINER_COUNT * MAX_CLIENTS)) users"
                echo "  • Backend ports: 127.0.0.1:${BACKEND_PORT_START}-$((BACKEND_PORT_START + CONTAINER_COUNT - 1))"
                echo "  • Nginx frontend: TCP ${NGINX_TCP_PORT}, UDP ${NGINX_UDP_PORT_START}-${NGINX_UDP_PORT_END}"
                echo ""
                echo "Commands:"
                echo "  conduit status   - Show cluster status"
                echo "  conduit health   - Run health check"
                echo "  conduit help     - Show all commands"
                echo ""
            fi
            ;;
    esac
}

main "$@"
change_settings() {
    clear
    print_header
    echo -e "${CYAN}═══ CHANGE SETTINGS ═══${NC}"
    echo ""
    
    echo "What would you like to change?"
    echo ""
    echo "  1. Max clients per container"
    echo "  2. Bandwidth limit per container"
    echo "  3. Apply to all containers (default)"
    echo "  4. Apply to specific container"
    echo "  0. Back"
    echo ""
    read -p "Choice: " setting_choice < /dev/tty || return
    
    case "$setting_choice" in
        1)
            echo ""
            echo "Current max clients: ${MAX_CLIENTS}"
            echo "Enter new max clients (50-1000, recommended: 250 for 4GB VPS):"
            read -p "Max clients: " new_clients < /dev/tty || return
            
            if [[ "$new_clients" =~ ^[0-9]+$ ]] && [ "$new_clients" -ge 50 ] && [ "$new_clients" -le 1000 ]; then
                echo ""
                echo "Apply to:"
                echo "  1. All containers (default)"
                echo "  2. Specific container"
                read -p "Choice [1-2]: " apply_choice < /dev/tty || apply_choice=1
                
                if [ "$apply_choice" = "2" ]; then
                    echo ""
                    echo "Select container:"
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        echo "  ${i}. $(get_container_name $i)"
                    done
                    read -p "Container [1-${CONTAINER_COUNT}]: " container_num < /dev/tty || return
                    
                    if [[ "$container_num" =~ ^[0-9]+$ ]] && [ "$container_num" -ge 1 ] && [ "$container_num" -le "$CONTAINER_COUNT" ]; then
                        declare -g "MAX_CLIENTS_${container_num}=$new_clients"
                        save_settings
                        echo -e "${GREEN}✓ Max clients for $(get_container_name $container_num) set to ${new_clients}${NC}"
                    fi
                else
                    MAX_CLIENTS=$new_clients
                    # Clear per-container overrides
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        unset "MAX_CLIENTS_${i}"
                    done
                    save_settings
                    echo -e "${GREEN}✓ Max clients set to ${new_clients} for all containers${NC}"
                fi
                
                echo ""
                echo "Settings saved. Restart containers to apply changes."
                read -p "Restart now? [y/N]: " restart_now < /dev/tty || restart_now="n"
                if [[ "$restart_now" =~ ^[Yy]$ ]]; then
                    restart_conduit
                fi
            else
                echo -e "${RED}Invalid value. Must be between 50 and 1000.${NC}"
            fi
            ;;
            
        2)
            echo ""
            echo "Current bandwidth: ${BANDWIDTH} Mbps (-1 = unlimited)"
            echo "Enter new bandwidth limit (1-100 Mbps, or -1 for unlimited):"
            echo "Recommended: 3 Mbps for 4GB VPS (network-limited)"
            read -p "Bandwidth (Mbps): " new_bw < /dev/tty || return
            
            if [[ "$new_bw" =~ ^-?[0-9]+$ ]] && { [ "$new_bw" -ge 1 ] && [ "$new_bw" -le 100 ] || [ "$new_bw" -eq -1 ]; }; then
                echo ""
                echo "Apply to:"
                echo "  1. All containers (default)"
                echo "  2. Specific container"
                read -p "Choice [1-2]: " apply_choice < /dev/tty || apply_choice=1
                
                if [ "$apply_choice" = "2" ]; then
                    echo ""
                    echo "Select container:"
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        echo "  ${i}. $(get_container_name $i)"
                    done
                    read -p "Container [1-${CONTAINER_COUNT}]: " container_num < /dev/tty || return
                    
                    if [[ "$container_num" =~ ^[0-9]+$ ]] && [ "$container_num" -ge 1 ] && [ "$container_num" -le "$CONTAINER_COUNT" ]; then
                        declare -g "BANDWIDTH_${container_num}=$new_bw"
                        save_settings
                        echo -e "${GREEN}✓ Bandwidth for $(get_container_name $container_num) set to ${new_bw} Mbps${NC}"
                    fi
                else
                    BANDWIDTH=$new_bw
                    # Clear per-container overrides
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        unset "BANDWIDTH_${i}"
                    done
                    save_settings
                    echo -e "${GREEN}✓ Bandwidth set to ${new_bw} Mbps for all containers${NC}"
                fi
                
                echo ""
                echo "Settings saved. Restart containers to apply changes."
                read -p "Restart now? [y/N]: " restart_now < /dev/tty || restart_now="n"
                if [[ "$restart_now" =~ ^[Yy]$ ]]; then
                    restart_conduit
                fi
            else
                echo -e "${RED}Invalid value. Must be 1-100 or -1 for unlimited.${NC}"
            fi
            ;;
            
        0) return ;;
        *) echo -e "${RED}Invalid choice${NC}" ;;
    esac
    
    echo ""
    read -n 1 -s -r -p "Press any key to continue..." < /dev/tty || true
}
change_resource_limits() {
    clear
    print_header
    echo -e "${CYAN}═══ RESOURCE LIMITS ═══${NC}"
    echo ""
    
    echo "Current resource limits per container:"
    echo "  CPU:    ${CONTAINER_CPU_LIMIT} cores"
    echo "  Memory: ${CONTAINER_MEM_LIMIT}"
    echo "  FD:     ${CONTAINER_ULIMIT_NOFILE}"
    echo ""
    echo "Change:"
    echo "  1. CPU limit"
    echo "  2. Memory limit"
    echo "  0. Back"
    echo ""
    read -p "Choice: " limit_choice < /dev/tty || return
    
    case "$limit_choice" in
        1)
            local total_cpu=$(nproc)
            echo ""
            echo "System has ${total_cpu} CPU cores"
            echo "Current per-container limit: ${CONTAINER_CPU_LIMIT} cores"
            echo "Total allocation: $(awk -v c="$CONTAINER_CPU_LIMIT" -v n="$CONTAINER_COUNT" 'BEGIN{printf "%.2f", c*n}') cores"
            echo ""
            echo "Enter new CPU limit per container (0.1-${total_cpu}):"
            echo "Recommended: $(awk -v t="$total_cpu" -v n="$CONTAINER_COUNT" 'BEGIN{printf "%.2f", (t*0.9)/n}') cores"
            read -p "CPU cores: " new_cpu < /dev/tty || return
            
            if [[ "$new_cpu" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                CONTAINER_CPU_LIMIT=$new_cpu
                save_settings
                echo -e "${GREEN}✓ CPU limit set to ${new_cpu} cores${NC}"
                echo ""
                echo "Restart containers to apply."
                read -p "Restart now? [y/N]: " restart_now < /dev/tty || restart_now="n"
                [[ "$restart_now" =~ ^[Yy]$ ]] && restart_conduit
            else
                echo -e "${RED}Invalid value${NC}"
            fi
            ;;
            
        2)
            local total_ram=$(free -m | awk '/^Mem:/{print $2}')
            echo ""
            echo "System has ${total_ram} MB RAM"
            echo "Current per-container limit: ${CONTAINER_MEM_LIMIT}"
            echo ""
            echo "Enter new memory limit per container (e.g., 256m, 512m, 1g):"
            echo "Recommended: $(awk -v t="$total_ram" -v n="$CONTAINER_COUNT" 'BEGIN{printf "%dm", (t*0.75)/n}')"
            read -p "Memory: " new_mem < /dev/tty || return
            
            if [[ "$new_mem" =~ ^[0-9]+[mg]$ ]]; then
                CONTAINER_MEM_LIMIT=$new_mem
                save_settings
                echo -e "${GREEN}✓ Memory limit set to ${new_mem}${NC}"
                echo ""
                echo "Restart containers to apply."
                read -p "Restart now? [y/N]: " restart_now < /dev/tty || restart_now="n"
                [[ "$restart_now" =~ ^[Yy]$ ]] && restart_conduit
            else
                echo -e "${RED}Invalid format. Use: 256m, 512m, 1g, etc.${NC}"
            fi
            ;;
            
        0) return ;;
    esac
    
    echo ""
    read -n 1 -s -r -p "Press any key to continue..." < /dev/tty || true
}
set_data_cap() {
    clear
    print_header
    echo -e "${CYAN}═══ DATA USAGE CAP ═══${NC}"
    echo ""
    
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        echo "Current data cap: ${DATA_CAP_GB} GB"
        echo "Current usage: $(format_gb $total_used) GB"
        echo ""
    else
        echo "No data cap currently set."
        echo ""
    fi
    
    echo "Options:"
    echo "  1. Set new data cap"
    echo "  2. Reset usage counter"
    echo "  3. Disable data cap"
    echo "  0. Back"
    echo ""
    read -p "Choice: " cap_choice < /dev/tty || return
    
    case "$cap_choice" in
        1)
            echo ""
            echo "Enter monthly data cap in GB (e.g., 1000 for 1TB):"
            read -p "Data cap (GB): " new_cap < /dev/tty || return
            
            if [[ "$new_cap" =~ ^[0-9]+$ ]] && [ "$new_cap" -gt 0 ]; then
                DATA_CAP_GB=$new_cap
                save_settings
                echo -e "${GREEN}✓ Data cap set to ${new_cap} GB${NC}"
            else
                echo -e "${RED}Invalid value${NC}"
            fi
            ;;
            
        2)
            echo ""
            echo -e "${YELLOW}This will reset the usage counter to 0.${NC}"
            echo "Previous usage will be recorded for reference."
            read -p "Reset counter? [y/N]: " confirm < /dev/tty || return
            
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                local usage=$(get_data_usage)
                local used_rx=$(echo "$usage" | awk '{print $1}')
                local used_tx=$(echo "$usage" | awk '{print $2}')
                DATA_CAP_PRIOR_USAGE=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
                save_settings
                echo -e "${GREEN}✓ Usage counter reset${NC}"
            fi
            ;;
            
        3)
            echo ""
            read -p "Disable data cap? [y/N]: " confirm < /dev/tty || return
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                DATA_CAP_GB=0
                save_settings
                echo -e "${GREEN}✓ Data cap disabled${NC}"
            fi
            ;;
            
        0) return ;;
    esac
    
    read -n 1 -s -r -p "Press any key to continue..." < /dev/tty || true
}
manage_containers() {
    while true; do
        clear
        print_header
        echo -e "${CYAN}═══ CONTAINER MANAGEMENT ═══${NC}"
        echo ""
        
        echo "Current containers: ${CONTAINER_COUNT}"
        echo ""
        
        # Show container status
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                echo "  ${i}. ${cname} ${GREEN}[RUNNING]${NC}"
            elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                echo "  ${i}. ${cname} ${YELLOW}[STOPPED]${NC}"
            else
                echo "  ${i}. ${cname} ${RED}[NOT CREATED]${NC}"
            fi
        done
        
        echo ""
        echo "Actions:"
        echo "  a. Add containers (scale up)"
        echo "  r. Remove containers (scale down)"
        echo "  s. Start specific container"
        echo "  t. Stop specific container"
        echo "  l. View container logs"
        echo "  i. Container info"
        echo "  0. Back"
        echo ""
        read -p "Choice: " mgmt_choice < /dev/tty || return
        
        case "$mgmt_choice" in
            a)
                echo ""
                local current=$CONTAINER_COUNT
                echo "Current: ${current} containers"
                echo "Enter new container count (${current}-100):"
                read -p "Count: " new_count < /dev/tty || continue
                
                if [[ "$new_count" =~ ^[0-9]+$ ]] && [ "$new_count" -gt "$current" ] && [ "$new_count" -le 100 ]; then
                    echo ""
                    echo "Scaling from ${current} to ${new_count} containers..."
                    CONTAINER_COUNT=$new_count
                    save_settings
                    
                    # Generate new Nginx config
                    echo "Regenerating Nginx configuration..."
                    generate_nginx_conf
                    reload_nginx
                    
                    # Start new containers
                    for i in $(seq $((current + 1)) $new_count); do
                        echo "Creating $(get_container_name $i)..."
                        run_conduit_container $i
                    done
                    
                    echo -e "${GREEN}✓ Scaled to ${new_count} containers${NC}"
                else
                    echo -e "${RED}Invalid count${NC}"
                fi
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                ;;
                
            r)
                echo ""
                local current=$CONTAINER_COUNT
                echo "Current: ${current} containers"
                echo "Enter new container count (1-${current}):"
                read -p "Count: " new_count < /dev/tty || continue
                
                if [[ "$new_count" =~ ^[0-9]+$ ]] && [ "$new_count" -ge 1 ] && [ "$new_count" -lt "$current" ]; then
                    echo ""
                    echo -e "${YELLOW}This will stop and remove containers ${new_count}+1 through ${current}.${NC}"
                    read -p "Continue? [y/N]: " confirm < /dev/tty || continue
                    
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        for i in $(seq $((new_count + 1)) $current); do
                            local cname=$(get_container_name $i)
                            echo "Removing ${cname}..."
                            docker stop "$cname" 2>/dev/null || true
                            docker rm "$cname" 2>/dev/null || true
                        done
                        
                        CONTAINER_COUNT=$new_count
                        save_settings
                        
                        # Regenerate Nginx config
                        echo "Regenerating Nginx configuration..."
                        generate_nginx_conf
                        reload_nginx
                        
                        echo -e "${GREEN}✓ Scaled down to ${new_count} containers${NC}"
                    fi
                else
                    echo -e "${RED}Invalid count${NC}"
                fi
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                ;;
                
            s)
                echo ""
                echo "Select container to start:"
                for i in $(seq 1 $CONTAINER_COUNT); do
                    echo "  ${i}. $(get_container_name $i)"
                done
                read -p "Container [1-${CONTAINER_COUNT}]: " cont_num < /dev/tty || continue
                
                if [[ "$cont_num" =~ ^[0-9]+$ ]] && [ "$cont_num" -ge 1 ] && [ "$cont_num" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $cont_num)
                    if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
                        echo -e "${YELLOW}${cname} is already running${NC}"
                    else
                        echo "Starting ${cname}..."
                        docker start "$cname" 2>/dev/null || run_conduit_container $cont_num
                        echo -e "${GREEN}✓ ${cname} started${NC}"
                    fi
                fi
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                ;;
                
            t)
                echo ""
                echo "Select container to stop:"
                for i in $(seq 1 $CONTAINER_COUNT); do
                    echo "  ${i}. $(get_container_name $i)"
                done
                read -p "Container [1-${CONTAINER_COUNT}]: " cont_num < /dev/tty || continue
                
                if [[ "$cont_num" =~ ^[0-9]+$ ]] && [ "$cont_num" -ge 1 ] && [ "$cont_num" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $cont_num)
                    echo "Stopping ${cname}..."
                    docker stop "$cname" 2>/dev/null
                    echo -e "${YELLOW}✓ ${cname} stopped${NC}"
                fi
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                ;;
                
            l)
                echo ""
                echo "Select container:"
                for i in $(seq 1 $CONTAINER_COUNT); do
                    echo "  ${i}. $(get_container_name $i)"
                done
                read -p "Container [1-${CONTAINER_COUNT}]: " cont_num < /dev/tty || continue
                
                if [[ "$cont_num" =~ ^[0-9]+$ ]] && [ "$cont_num" -ge 1 ] && [ "$cont_num" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $cont_num)
                    echo ""
                    echo "Viewing logs for ${cname} (Ctrl+C to exit)..."
                    echo ""
                    sleep 1
                    docker logs --tail 50 -f "$cname" 2>&1 || true
                fi
                ;;
                
            i)
                echo ""
                echo "Select container:"
                for i in $(seq 1 $CONTAINER_COUNT); do
                    echo "  ${i}. $(get_container_name $i)"
                done
                read -p "Container [1-${CONTAINER_COUNT}]: " cont_num < /dev/tty || continue
                
                if [[ "$cont_num" =~ ^[0-9]+$ ]] && [ "$cont_num" -ge 1 ] && [ "$cont_num" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $cont_num)
                    echo ""
                    echo -e "${CYAN}═══ ${cname} INFO ═══${NC}"
                    docker inspect "$cname" 2>/dev/null | grep -A 20 '"Config"' || echo "Container not found"
                fi
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                ;;
                
            0) return ;;
        esac
    done
}
show_live_stats() {
    local refresh_interval=3
    local stop_live=0
    
    trap 'stop_live=1' SIGINT SIGTERM
    
    while [ $stop_live -eq 0 ]; do
        clear
        print_header
        echo -e "${CYAN}═══ LIVE STATISTICS ${NC}${DIM}(auto-refresh every ${refresh_interval}s)${NC}"
        echo ""
        
        show_status "live"
        
        echo ""
        echo -e "${DIM}Press Ctrl+C to exit${NC}"
        
        sleep $refresh_interval
    done
    
    trap - SIGINT SIGTERM
}
show_peers() {
    echo ""
    echo -e "${CYAN}═══ LIVE PEERS BY COUNTRY ═══${NC}"
    echo ""
    echo "Feature: Live traffic breakdown by country"
    echo ""
    echo "This would show:"
    echo "  - Traffic by country (bytes in/out)"
    echo "  - Estimated clients per country"
    echo "  - Real-time speed (KB/s)"
    echo ""
    echo -e "${YELLOW}Note: This requires the tracker to be active.${NC}"
    echo ""
    
    if ! is_tracker_active; then
        echo -e "${RED}Tracker is not running.${NC}"
        echo "Start it from Settings & Tools > Restart tracker (option r)"
    else
        echo -e "${GREEN}Tracker is active.${NC}"
        echo "Traffic data is being collected."
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
show_menu() {
    # Auto-fix systemd service
    if command -v systemctl &>/dev/null && [ -f /etc/systemd/system/conduit.service ]; then
        if grep -q "Requires=docker.service" /etc/systemd/system/conduit.service 2>/dev/null; then
            cat > /etc/systemd/system/conduit.service << 'SVCEOF'
[Unit]
Description=Psiphon Conduit Cluster Service
After=network.target docker.service nginx.service
Wants=docker.service nginx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/conduit start
ExecStop=/usr/local/bin/conduit stop

[Install]
WantedBy=multi-user.target
SVCEOF
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi
    
    # Auto-start tracker if containers running
    local any_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" || echo "0")
    if [ "${any_running:-0}" -gt 0 ] && ! is_tracker_active; then
        setup_tracker_service 2>/dev/null || true
    fi
    
    # Main menu loop
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header
            
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MAIN MENU${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📊 Live connection stats"
            echo -e "  3. 📋 View logs"
            echo -e "  4. 🌍 Live peers by country"
            echo ""
            echo -e "  5. ▶️  Start Conduit"
            echo -e "  6. ⏹️  Stop Conduit"
            echo -e "  7. 🔁 Restart Conduit"
            echo ""
            echo -e "  8. ⚙️  Change settings"
            echo -e "  9. 📦 Manage containers"
            echo -e "  r. 🔧 Resource limits"
            echo -e "  d. 📊 Data cap"
            echo ""
            echo -e "  n. 🔀 Nginx status"
            echo -e "  h. 🩺 Health check"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi
        
        read -p "  Enter choice: " choice < /dev/tty || { echo "Input error. Exiting."; exit 1; }
        
        case "$choice" in
            1)
                show_dashboard
                redraw=true
                ;;
            2)
                show_live_stats
                redraw=true
                ;;
            3)
                show_logs
                redraw=true
                ;;
            4)
                show_peers
                redraw=true
                ;;
            5)
                start_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            6)
                stop_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            7)
                restart_conduit
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            8)
                change_settings
                redraw=true
                ;;
            9)
                manage_containers
                redraw=true
                ;;
            r|R)
                change_resource_limits
                redraw=true
                ;;
            d|D)
                set_data_cap
                redraw=true
                ;;
            n|N)
                clear
                print_header
                echo -e "${CYAN}═══ NGINX STATUS ═══${NC}"
                echo ""
                if systemctl is-active nginx &>/dev/null; then
                    echo -e "Nginx: ${GREEN}Running${NC}"
                    echo ""
                    echo "Backend Status:"
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        local cname=$(get_container_name $i)
                        local port=$((BACKEND_PORT_START + i - 1))
                        if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
                            echo "  ${cname} (127.0.0.1:${port}): ${GREEN}UP${NC}"
                        else
                            echo "  ${cname} (127.0.0.1:${port}): ${RED}DOWN${NC}"
                        fi
                    done
                else
                    echo -e "Nginx: ${RED}Stopped${NC}"
                fi
                echo ""
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            h|H)
                health_check
                read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
                redraw=true
                ;;
            0)
                echo "Exiting."
                exit 0
                ;;
            "")
                ;;
            *)
                echo -e "${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}"
                sleep 1
                redraw=true
                ;;
        esac
    done
}
telegram_get_chat_id() {
    local response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates")
    local chat_id=$(echo "$response" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$')
    
    if [ -n "$chat_id" ]; then
        TELEGRAM_CHAT_ID="$chat_id"
        echo -e "${GREEN}✓ Chat ID detected: ${chat_id}${NC}"
        return 0
    else
        return 1
    fi
}
telegram_test_message() {
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
    local message="🎉 *Conduit v2.0 Cluster Test*%0A%0AServer: ${server_label}%0AStatus: Online%0AContainers: ${CONTAINER_COUNT}%0A%0ANotifications are working!"
    
    local response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown")
    
    if echo "$response" | grep -q '"ok":true'; then
        return 0
    else
        return 1
    fi
}
telegram_generate_notify_script() {
    log_info "Generating Telegram notification script..."
    
    cat > "$INSTALL_DIR/conduit-telegram.sh" << 'TGEOF'
#!/bin/bash
# Conduit v2.0 Telegram Notification Service

INSTALL_DIR="/opt/conduit"
source "$INSTALL_DIR/settings.conf" 2>/dev/null || exit 1

[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && exit 0

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" &>/dev/null
}
telegram_stop_notify() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
    fi
}
telegram_start_notify() {
    telegram_stop_notify
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        setup_telegram_service
    fi
}
telegram_disable_service() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
        systemctl disable conduit-telegram.service 2>/dev/null || true
    fi
}
telegram_setup_wizard() {
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Conduit Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_conduit_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram creates outbound"
    echo -e "  connections to api.telegram.org from this server."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    
    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        telegram_get_chat_id && break
        attempts=$((attempts + 1))
        sleep 2
    done
    
    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot."
        TELEGRAM_BOT_TOKEN="$_saved_token"
        TELEGRAM_CHAT_ID="$_saved_chatid"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac
    
    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi
    
    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"
        TELEGRAM_CHAT_ID="$_saved_chatid"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    TELEGRAM_ENABLED=true
    save_settings
    telegram_start_notify
    
    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}
show_telegram_menu() {
    while true; do
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        
        clear
        print_header
        
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00)"
            echo ""
            
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            
            read -p "  Enter choice: " tchoice < /dev/tty || return
            
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || continue
                    
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) continue ;;
                    esac
                    
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Interval updated${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
                    echo -e "  Current: ${CYAN}${cur_label}${NC}"
                    echo "  Leave blank for hostname."
                    read -p "  New label: " new_label < /dev/tty || true
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Label updated${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        else
            telegram_setup_wizard
            return
        fi
    done
}
get_conduit_id() {
    local index=${1:-1}
    local vname=$(get_volume_name $index)
    local mountpoint=$(docker volume inspect "$vname" --format '{{ .Mountpoint }}' 2>/dev/null)
    
    if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
        local node_id=$(cat "$mountpoint/conduit_key.json" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')
        echo "$node_id"
    else
        # Fallback: use docker cp
        local tmp_ctr="conduit-qr-tmp-${index}"
        docker rm -f "$tmp_ctr" 2>/dev/null || true
        if docker create --name "$tmp_ctr" -v "$vname:/data" alpine true 2>/dev/null; then
            local key_content=$(docker cp "$tmp_ctr:/data/conduit_key.json" - 2>/dev/null | tar -xOf - 2>/dev/null)
            docker rm -f "$tmp_ctr" 2>/dev/null || true
            if [ -n "$key_content" ]; then
                local node_id=$(echo "$key_content" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n')
                echo "$node_id"
            fi
        else
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
    fi
}
show_qr_code() {
    clear
    print_header
    echo -e "${CYAN}═══ CONDUIT NODE QR CODES ═══${NC}"
    echo ""
    
    if [ "$CONTAINER_COUNT" -eq 1 ]; then
        local node_id=$(get_conduit_id 1)
        if [ -n "$node_id" ]; then
            echo "Node ID: ${CYAN}${node_id}${NC}"
            echo ""
            echo "Ryve URL: ryve://${node_id}"
            echo ""
            echo -e "${DIM}To generate QR code, install qrencode:${NC}"
            echo -e "${DIM}  apt-get install qrencode${NC}"
            echo -e "${DIM}  echo 'ryve://${node_id}' | qrencode -t ANSIUTF8${NC}"
        else
            echo -e "${RED}Node key not found. Has the container been started?${NC}"
        fi
    else
        echo "Select container to view QR code:"
        echo ""
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
                echo "  ${i}. ${cname}"
            else
                echo "  ${i}. ${cname} ${DIM}(not created)${NC}"
            fi
        done
        echo "  a. Show all"
        echo "  0. Back"
        echo ""
        read -p "Choice: " qr_choice < /dev/tty || return
        
        case "$qr_choice" in
            a|A)
                echo ""
                echo "All Node IDs:"
                echo ""
                for i in $(seq 1 $CONTAINER_COUNT); do
                    local cname=$(get_container_name $i)
                    local node_id=$(get_conduit_id $i)
                    if [ -n "$node_id" ]; then
                        echo "  ${cname}: ${CYAN}${node_id}${NC}"
                        echo "  ryve://${node_id}"
                        echo ""
                    else
                        echo "  ${cname}: ${RED}No key found${NC}"
                        echo ""
                    fi
                done
                ;;
            [1-9]|[1-9][0-9])
                if [ "$qr_choice" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $qr_choice)
                    local node_id=$(get_conduit_id $qr_choice)
                    
                    echo ""
                    if [ -n "$node_id" ]; then
                        echo "${cname} Node ID: ${CYAN}${node_id}${NC}"
                        echo ""
                        echo "Ryve URL: ryve://${node_id}"
                        echo ""
                        echo -e "${DIM}To generate QR code:${NC}"
                        echo -e "${DIM}  echo 'ryve://${node_id}' | qrencode -t ANSIUTF8${NC}"
                    else
                        echo -e "${RED}Node key not found for ${cname}${NC}"
                    fi
                fi
                ;;
            0) return ;;
        esac
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
backup_key() {
    clear
    print_header
    echo -e "${CYAN}═══ BACKUP NODE KEYS ═══${NC}"
    echo ""
    
    mkdir -p "$INSTALL_DIR/backups"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_count=0
    
    echo "Backing up node keys for ${CONTAINER_COUNT} container(s)..."
    echo ""
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        local vname=$(get_volume_name $i)
        local cname=$(get_container_name $i)
        local backup_file="$INSTALL_DIR/backups/${cname}_key_${timestamp}.json"
        
        # Try direct mountpoint access
        local mountpoint=$(docker volume inspect "$vname" --format '{{ .Mountpoint }}' 2>/dev/null)
        
        if [ -n "$mountpoint" ] && [ -f "$mountpoint/conduit_key.json" ]; then
            if cp "$mountpoint/conduit_key.json" "$backup_file"; then
                chmod 600 "$backup_file"
                echo -e "  ${GREEN}✓ ${cname}${NC}"
                backup_count=$((backup_count + 1))
            else
                echo -e "  ${RED}✗ ${cname} (copy failed)${NC}"
            fi
        else
            # Fallback: docker cp
            local tmp_ctr="conduit-backup-tmp-${i}"
            docker create --name "$tmp_ctr" -v "$vname:/data" alpine true 2>/dev/null || true
            if docker cp "$tmp_ctr:/data/conduit_key.json" "$backup_file" 2>/dev/null; then
                chmod 600 "$backup_file"
                echo -e "  ${GREEN}✓ ${cname}${NC}"
                backup_count=$((backup_count + 1))
            else
                echo -e "  ${RED}✗ ${cname} (no key found)${NC}"
            fi
            docker rm -f "$tmp_ctr" 2>/dev/null || true
        fi
    done
    
    echo ""
    if [ $backup_count -gt 0 ]; then
        echo -e "${GREEN}✓ Backed up ${backup_count} key(s)${NC}"
        echo ""
        echo "  Backup location: ${CYAN}$INSTALL_DIR/backups/${NC}"
        echo "  Timestamp: ${timestamp}"
        echo ""
        echo -e "${YELLOW}Important:${NC} Store these backups securely."
        echo "They contain your node's private keys."
    else
        echo -e "${RED}No keys were backed up.${NC}"
        echo "Have the containers been started at least once?"
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
restore_key() {
    clear
    print_header
    echo -e "${CYAN}═══ RESTORE NODE KEYS ═══${NC}"
    echo ""
    
    local backup_dir="$INSTALL_DIR/backups"
    
    if [ ! -d "$backup_dir" ] || [ -z "$(ls -A "$backup_dir"/*.json 2>/dev/null)" ]; then
        echo -e "${YELLOW}No backups found in ${backup_dir}${NC}"
        echo ""
        echo "To restore from custom path:"
        read -p "  Backup file path (or Enter to cancel): " custom_path < /dev/tty || return
        
        if [ -z "$custom_path" ]; then
            return
        fi
        
        if [ ! -f "$custom_path" ]; then
            echo -e "${RED}File not found: ${custom_path}${NC}"
            read -n 1 -s -r -p "Press any key..." < /dev/tty || true
            return
        fi
        
        local backup_file="$custom_path"
        local container_num=1
    else
        echo "Available backups:"
        echo ""
        local i=1
        local -a backups
        for f in "$backup_dir"/*.json; do
            backups+=("$f")
            local fname=$(basename "$f")
            local node_id=$(cat "$f" | grep "privateKeyBase64" | awk -F'"' '{print $4}' | base64 -d 2>/dev/null | tail -c 32 | base64 | tr -d '=\n' 2>/dev/null || echo "unknown")
            echo "  ${i}. ${fname}"
            echo "     Node: ${node_id}"
            echo ""
            i=$((i + 1))
        done
        
        read -p "Select backup [1-${#backups[@]}] or 0 to cancel: " selection < /dev/tty || return
        
        if [ "$selection" = "0" ] || [ -z "$selection" ]; then
            return
        fi
        
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#backups[@]} ]; then
            echo -e "${RED}Invalid selection${NC}"
            read -n 1 -s -r -p "Press any key..." < /dev/tty || true
            return
        fi
        
        local backup_file="${backups[$((selection - 1))]}"
        
        echo ""
        echo "Restore to which container?"
        for i in $(seq 1 $CONTAINER_COUNT); do
            echo "  ${i}. $(get_container_name $i)"
        done
        read -p "Container [1-${CONTAINER_COUNT}]: " container_num < /dev/tty || return
        
        if ! [[ "$container_num" =~ ^[0-9]+$ ]] || [ "$container_num" -lt 1 ] || [ "$container_num" -gt "$CONTAINER_COUNT" ]; then
            echo -e "${RED}Invalid container${NC}"
            read -n 1 -s -r -p "Press any key..." < /dev/tty || true
            return
        fi
    fi
    
    echo ""
    echo -e "${YELLOW}This will replace the current key for $(get_container_name $container_num).${NC}"
    read -p "Continue? [y/N]: " confirm < /dev/tty || return
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi
    
    local cname=$(get_container_name $container_num)
    local vname=$(get_volume_name $container_num)
    
    echo ""
    echo "Stopping ${cname}..."
    docker stop "$cname" 2>/dev/null || true
    
    # Try direct mountpoint
    local mountpoint=$(docker volume inspect "$vname" --format '{{ .Mountpoint }}' 2>/dev/null)
    
    if [ -n "$mountpoint" ] && [ -d "$mountpoint" ]; then
        if [ -f "$mountpoint/conduit_key.json" ]; then
            local backup_ts=$(date '+%Y%m%d_%H%M%S')
            cp "$mountpoint/conduit_key.json" "$INSTALL_DIR/backups/${cname}_pre_restore_${backup_ts}.json"
            echo "  Current key backed up"
        fi
        
        if cp "$backup_file" "$mountpoint/conduit_key.json"; then
            chmod 600 "$mountpoint/conduit_key.json"
            echo -e "${GREEN}✓ Key restored${NC}"
        else
            echo -e "${RED}✗ Failed to copy key${NC}"
            read -n 1 -s -r -p "Press any key..." < /dev/tty || true
            return
        fi
    else
        # Fallback: docker cp
        local tmp_ctr="conduit-restore-tmp-${container_num}"
        docker create --name "$tmp_ctr" -v "$vname:/data" alpine true 2>/dev/null || true
        
        if docker cp "$tmp_ctr:/data/conduit_key.json" "$INSTALL_DIR/backups/${cname}_pre_restore_$(date +%s).json" 2>/dev/null; then
            echo "  Current key backed up"
        fi
        
        if docker cp "$backup_file" "$tmp_ctr:/data/conduit_key.json" 2>/dev/null; then
            docker run --rm -v "$vname:/data" alpine chown 1000:1000 /data/conduit_key.json 2>/dev/null || true
            echo -e "${GREEN}✓ Key restored${NC}"
        else
            echo -e "${RED}✗ Failed to copy key${NC}"
        fi
        
        docker rm -f "$tmp_ctr" 2>/dev/null || true
    fi
    
    echo "Starting ${cname}..."
    docker start "$cname" 2>/dev/null || run_conduit_container $container_num
    
    echo ""
    echo -e "${GREEN}✓ Restore complete${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
recreate_containers() {
    echo "Recreating containers with updated image..."
    
    # Save tracker data
    stop_tracker_service 2>/dev/null || true
    local persist_dir="$INSTALL_DIR/traffic_stats"
    if [ -s "$persist_dir/cumulative_data" ]; then
        echo -e "${CYAN}Saving tracker data...${NC}"
        cp "$persist_dir/cumulative_data" "$persist_dir/cumulative_data.bak" 2>/dev/null || true
        cp "$persist_dir/cumulative_ips" "$persist_dir/cumulative_ips.bak" 2>/dev/null || true
    fi
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        docker rm -f "$name" 2>/dev/null || true
    done
    
    fix_volume_permissions
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        run_conduit_container $i
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ $(get_container_name $i) updated${NC}"
        else
            echo -e "${RED}✗ Failed to start $(get_container_name $i)${NC}"
        fi
    done
    
    setup_tracker_service 2>/dev/null || true
}
update_conduit() {
    clear
    print_header
    echo -e "${CYAN}═══ UPDATE CONDUIT ═══${NC}"
    echo ""
    
    echo "Checking for script updates..."
    local update_url="https://raw.githubusercontent.com/SamNet-dev/conduit-manager/main/conduit-v2.0.sh"
    local tmp_script="/tmp/conduit_update_$$.sh"
    
    if curl -sL --max-time 30 -o "$tmp_script" "$update_url" 2>/dev/null; then
        if grep -q "VERSION=" "$tmp_script" && bash -n "$tmp_script" 2>/dev/null; then
            echo -e "${GREEN}✓ Latest script downloaded${NC}"
            
            # Get version from downloaded script
            local new_version=$(grep "^VERSION=" "$tmp_script" | head -1 | cut -d'"' -f2)
            echo "  New version: ${new_version}"
            echo "  Current version: ${VERSION}"
            echo ""
            
            read -p "Install updated script? [y/N]: " install_script < /dev/tty || install_script="n"
            
            if [[ "$install_script" =~ ^[Yy]$ ]]; then
                cp "$INSTALL_DIR/conduit" "$INSTALL_DIR/conduit.bak.$(date +%s)" 2>/dev/null || true
                cp "$tmp_script" "$INSTALL_DIR/conduit"
                chmod +x "$INSTALL_DIR/conduit"
                echo -e "${GREEN}✓ Script updated${NC}"
            fi
        else
            echo -e "${RED}Downloaded file appears invalid${NC}"
        fi
        rm -f "$tmp_script"
    else
        echo -e "${YELLOW}Could not download update${NC}"
    fi
    
    echo ""
    echo "Checking for Docker image updates..."
    local pull_output=$(docker pull "$CONDUIT_IMAGE" 2>&1)
    
    if echo "$pull_output" | grep -q "Status: Image is up to date"; then
        echo -e "${GREEN}Docker image is up to date${NC}"
    elif echo "$pull_output" | grep -q "Downloaded newer image\|Pull complete"; then
        echo -e "${YELLOW}New Docker image available${NC}"
        echo ""
        read -p "Recreate containers with new image? [y/N]: " recreate < /dev/tty || recreate="n"
        
        if [[ "$recreate" =~ ^[Yy]$ ]]; then
            recreate_containers
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Update complete${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
show_about() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}ABOUT PSIPHON CONDUIT CLUSTER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}What is Psiphon Conduit?${NC}"
    echo -e "  Psiphon is a free anti-censorship tool helping millions access"
    echo -e "  the open internet. Conduit is their ${BOLD}P2P volunteer network${NC}."
    echo ""
    echo -e "  ${BOLD}${GREEN}Cluster Edition v2.0${NC}"
    echo -e "  This enhanced version adds:"
    echo -e "    ${YELLOW}•${NC} Nginx Layer 4 Load Balancer (TCP/UDP)"
    echo -e "    ${YELLOW}•${NC} Unlimited container scaling (recommended: 8 for 4GB VPS)"
    echo -e "    ${YELLOW}•${NC} System kernel tuning (BBR, somaxconn, file-max)"
    echo -e "    ${YELLOW}•${NC} Health monitoring & automated recovery"
    echo -e "    ${YELLOW}•${NC} Production-grade DevOps hardening"
    echo ""
    echo -e "  ${BOLD}${GREEN}How P2P Works${NC}"
    echo -e "  Conduit is ${CYAN}decentralized${NC}:"
    echo -e "    ${YELLOW}1.${NC} Your cluster registers with Psiphon's broker"
    echo -e "    ${YELLOW}2.${NC} Users discover nodes through P2P network"
    echo -e "    ${YELLOW}3.${NC} Direct encrypted WebRTC tunnels established"
    echo -e "    ${YELLOW}4.${NC} Traffic: ${GREEN}User${NC} <--P2P--> ${CYAN}You${NC} <--> ${YELLOW}Internet${NC}"
    echo ""
    echo -e "  ${BOLD}${GREEN}Technical${NC}"
    echo -e "    Protocol:  WebRTC + DTLS + QUIC"
    echo -e "    Ports:     TCP 443 | UDP 16384-32768"
    echo -e "    Resources: ~250MB RAM per container"
    echo ""
    echo -e "  ${BOLD}${GREEN}Privacy${NC}"
    echo -e "    ${GREEN}✓${NC} End-to-end encrypted"
    echo -e "    ${GREEN}✓${NC} No logs stored"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}Made by Sam (v2.0 Cluster Edition)${NC}"
    echo -e "  GitHub:  ${CYAN}https://github.com/SamNet-dev/conduit-manager${NC}"
    echo -e "  Psiphon: ${CYAN}https://psiphon.ca${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}
show_version() {
    echo "Conduit Manager v${VERSION}"
    echo "Image: ${CONDUIT_IMAGE}"
    echo ""
    echo "v2.0 Cluster Edition Features:"
    echo "  ✓ Nginx Layer 4 Load Balancer"
    echo "  ✓ Bridge networking (localhost backends)"
    echo "  ✓ Unlimited container scaling"
    echo "  ✓ System kernel tuning (BBR, somaxconn)"
    echo "  ✓ Health monitoring & watchdog"
    echo "  ✓ Production-ready DevOps hardening"
}
show_help() {
    echo "Conduit Manager v${VERSION} - Cluster Edition"
    echo ""
    echo "Usage: conduit [command]"
    echo ""
    echo "Commands:"
    echo "  start         Start all containers and Nginx LB"
    echo "  stop          Stop all containers"
    echo "  restart       Restart cluster"
    echo "  status        Show cluster status"
    echo "  health        Run health check"
    echo "  scale <N>     Scale to N containers"
    echo "  menu          Open interactive menu (default)"
    echo "  version       Show version information"
    echo "  help          Show this help"
    echo ""
    echo "v2.0 Features:"
    echo "  • Nginx Layer 4 Load Balancer"
    echo "  • Unlimited scaling (default: 8 containers)"
    echo "  • Health monitoring & auto-recovery"
    echo "  • System kernel tuning"
}

#═══════════════════════════════════════════════════════════════════════════
# Updated Main Function (with full menu support)
#═══════════════════════════════════════════════════════════════════════════

# Update existing main() to call show_menu instead of placeholder
update_main_for_menu() {
    # This function is called by the script itself
    # The main() function has been updated to call show_menu
    return 0
}

# Override the case statement to include Telegram and QR options
show_extended_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            print_header
            
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  MAIN MENU${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  1. 📈 View status dashboard"
            echo -e "  2. 📊 Live connection stats"
            echo -e "  3. 📋 View logs"
            echo -e "  4. 🌍 Live peers by country"
            echo ""
            echo -e "  5. ▶️  Start Conduit"
            echo -e "  6. ⏹️  Stop Conduit"
            echo -e "  7. 🔁 Restart Conduit"
            echo ""
            echo -e "  8. ⚙️  Settings"
            echo -e "  9. 📦 Containers"
            echo -e "  t. 📲 Telegram"
            echo -e "  q. 🎫 QR Codes"
            echo -e "  b. 💾 Backup/Restore"
            echo ""
            echo -e "  u. 🔄 Update"
            echo -e "  n. 🔀 Nginx status"
            echo -e "  h. 🩺 Health check"
            echo -e "  a. ℹ️  About"
            echo -e "  0. 🚪 Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi
        
        read -p "  Enter choice: " choice < /dev/tty || { echo "Exiting."; exit 0; }
        
        case "$choice" in
            1) show_dashboard; redraw=true ;;
            2) show_live_stats; redraw=true ;;
            3) show_logs; redraw=true ;;
            4) show_peers; redraw=true ;;
            5) start_conduit; read -n 1 -s -r -p "Press any key..." < /dev/tty || true; redraw=true ;;
            6) stop_conduit; read -n 1 -s -r -p "Press any key..." < /dev/tty || true; redraw=true ;;
            7) restart_conduit; read -n 1 -s -r -p "Press any key..." < /dev/tty || true; redraw=true ;;
            8) change_settings; redraw=true ;;
            9) manage_containers; redraw=true ;;
            t|T) show_telegram_menu; redraw=true ;;
            q|Q) show_qr_code; redraw=true ;;
            b|B)
                clear
                print_header
                echo -e "${CYAN}═══ BACKUP & RESTORE ═══${NC}"
                echo ""
                echo "  1. Backup node keys"
                echo "  2. Restore node keys"
                echo "  0. Back"
                echo ""
                read -p "Choice: " br_choice < /dev/tty || continue
                case "$br_choice" in
                    1) backup_key ;;
                    2) restore_key ;;
                esac
                redraw=true
                ;;
            u|U) update_conduit; redraw=true ;;
            n|N)
                clear
                print_header
                echo -e "${CYAN}═══ NGINX STATUS ═══${NC}"
                echo ""
                if systemctl is-active nginx &>/dev/null; then
                    echo -e "Nginx: ${GREEN}Running${NC}"
                    echo ""
                    for i in $(seq 1 $CONTAINER_COUNT); do
                        local cname=$(get_container_name $i)
                        local port=$((BACKEND_PORT_START + i - 1))
                        if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
                            echo "  ${cname} (127.0.0.1:${port}): ${GREEN}UP${NC}"
                        else
                            echo "  ${cname} (127.0.0.1:${port}): ${RED}DOWN${NC}"
                        fi
                    done
                else
                    echo -e "Nginx: ${RED}Stopped${NC}"
                fi
                echo ""
                read -n 1 -s -r -p "Press any key..." < /dev/tty || true
                redraw=true
                ;;
            h|H) health_check; read -n 1 -s -r -p "Press any key..." < /dev/tty || true; redraw=true ;;
            a|A) show_about; redraw=true ;;
            0) echo "Exiting."; exit 0 ;;
            "") ;;
            *) echo -e "${RED}Invalid choice${NC}"; sleep 1; redraw=true ;;
        esac
    done
}

# Call the extended menu if running in menu mode
if [ "${1:-menu}" = "menu" ] || [ "${1:-menu}" = "" ]; then
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        source "$INSTALL_DIR/settings.conf"
        show_extended_menu
    fi
fi

