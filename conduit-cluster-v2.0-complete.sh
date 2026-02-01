#!/bin/bash

#═══════════════════════════════════════════════════════════════════════════
# Psiphon Conduit Manager - High-Performance Cluster Edition v2.0 COMPLETE
#═══════════════════════════════════════════════════════════════════════════
# A complete management system for running Psiphon Conduit P2P proxy clusters
# with Nginx Layer 4 Load Balancer, system tuning, and comprehensive monitoring
#
# GitHub: https://github.com/SamNet-dev/conduit-manager
# Psiphon: https://psiphon.ca
#
# VERSION: 2.0.0-complete
# FEATURES: Full v1.x UI + Complete v2.0 Cluster Infrastructure
#═══════════════════════════════════════════════════════════════════════════

set -euo pipefail

VERSION="2.0.0-complete"
CONDUIT_IMAGE="psiphon/conduit:latest"
INSTALL_DIR="/opt/conduit"

# v2.0 Configuration (Hardware-Optimized for 4GB VPS)
DEFAULT_CONTAINER_COUNT=40
RECOMMENDED_CONTAINER_COUNT=8
DEFAULT_MAX_CLIENTS=250
DEFAULT_BANDWIDTH=3

# Container Resource Limits
CONTAINER_CPU_LIMIT="0.22"
CONTAINER_MEM_LIMIT="384m"
CONTAINER_ULIMIT_NOFILE="16384"

# Nginx Load Balancer Ports
NGINX_TCP_PORT=443
NGINX_UDP_PORT_START=16384
NGINX_UDP_PORT_END=32768
BACKEND_PORT_START=8081

# System Tuning Parameters
SYSCTL_SOMAXCONN=8192
SYSCTL_FILE_MAX=524288
SYSCTL_NETDEV_MAX_BACKLOG=5000

# Health Check Configuration
HEALTH_CHECK_INTERVAL=5
NGINX_WATCHDOG_INTERVAL=1

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
CONTAINER_COUNT="${RECOMMENDED_CONTAINER_COUNT}"
SYSTEM_TUNED=false
DATA_CAP_GB=0
DATA_CAP_PRIOR_USAGE=0
TELEGRAM_ENABLED=false
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""
TELEGRAM_INTERVAL=6
TELEGRAM_START_HOUR=0
TELEGRAM_ALERTS_ENABLED=true
TELEGRAM_DAILY_SUMMARY=true
TELEGRAM_WEEKLY_SUMMARY=true
TELEGRAM_SERVER_LABEL=""

#═══════════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════════

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

print_header() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Psiphon Conduit Manager${NC} - ${YELLOW}Cluster Edition v${VERSION}${NC}  ${CYAN}║${NC}"
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

get_container_name() {
    local index=${1:-1}
    if [ $index -eq 1 ]; then echo "conduit"; else echo "conduit-${index}"; fi
}

get_volume_name() {
    local index=${1:-1}
    if [ $index -eq 1 ]; then echo "conduit-data"; else echo "conduit-data-${index}"; fi
}

get_cpu_cores() {
    nproc 2>/dev/null || echo "1"
}

format_bytes() {
    local bytes=$1
    if [ "$bytes" -ge 1099511627776 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f TB", b/1099511627776}'
    elif [ "$bytes" -ge 1073741824 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f GB", b/1073741824}'
    elif [ "$bytes" -ge 1048576 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f MB", b/1048576}'
    elif [ "$bytes" -ge 1024 ]; then
        awk -v b="$bytes" 'BEGIN {printf "%.2f KB", b/1024}'
    else
        echo "${bytes} B"
    fi
}

format_number() {
    printf "%'d" "$1" 2>/dev/null || echo "$1"
}

format_gb() {
    awk -v b="$1" 'BEGIN {printf "%.2f", b/1073741824}'
}

get_container_max_clients() {
    local i=$1
    local var="MAX_CLIENTS_${i}"
    echo "${!var:-$MAX_CLIENTS}"
}

get_container_bandwidth() {
    local i=$1
    local var="BANDWIDTH_${i}"
    echo "${!var:-$BANDWIDTH}"
}

get_container_cpus() {
    local i=$1
    local var="CONTAINER_CPUS_${i}"
    echo "${!var:-$CONTAINER_CPU_LIMIT}"
}

get_container_memory() {
    local i=$1
    local var="CONTAINER_MEMORY_${i}"
    echo "${!var:-$CONTAINER_MEM_LIMIT}"
}

get_container_stats() {
    docker stats --no-stream --format "{{.CPUPerc}} {{.MemUsage}}" $(docker ps --filter "name=^conduit" --format "{{.Names}}") 2>/dev/null | awk '{
        cpu+=$1; gsub(/%/,"",$1); total_cpu+=$1
        split($2,mem,"/"); split(mem[1],used," "); split(mem[2],limit," ")
        if(used[2]=="GiB") used_val=used[1]*1024; else if(used[2]=="MiB") used_val=used[1]; else used_val=used[1]/1024
        if(limit[2]=="GiB") limit_val=limit[1]*1024; else if(limit[2]=="MiB") limit_val=limit[1]; else limit_val=limit[1]/1024
        total_used+=used_val; total_limit+=limit_val
    }
    END {printf "%.2f%% %.0fMiB / %.0fMiB", total_cpu, total_used, total_limit}'
}

get_system_stats() {
    local cpu_pct=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local mem_used=$(free -m | awk '/^Mem:/{print $3}')
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
    local mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.1f", (u/t)*100}')
    echo "${cpu_pct}% ${mem_used}MiB ${mem_total}MiB ${mem_pct}%"
}

get_net_speed() {
    local iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}')
    [ -z "$iface" ] && iface=$(ip route list default 2>/dev/null | awk '{print $5}')
    
    if [ -n "$iface" ] && [ -f "/sys/class/net/$iface/statistics/rx_bytes" ]; then
        local rx1=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx1=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        sleep 0.5
        local rx2=$(cat /sys/class/net/$iface/statistics/rx_bytes)
        local tx2=$(cat /sys/class/net/$iface/statistics/tx_bytes)
        local rx_delta=$((rx2 - rx1))
        local tx_delta=$((tx2 - tx1))
        local rx_mbps=$(awk -v b="$rx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        local tx_mbps=$(awk -v b="$tx_delta" 'BEGIN { printf "%.2f", (b * 16) / 1000000 }')
        echo "$rx_mbps $tx_mbps"
    else
        echo "0.00 0.00"
    fi
}

get_data_usage() {
    local total_rx=0
    local total_tx=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        local vname=$(get_volume_name $i)
        if docker volume inspect "$vname" &>/dev/null; then
            local rx=$(docker run --rm -v "$vname:/data" alpine cat /data/rx_bytes 2>/dev/null || echo "0")
            local tx=$(docker run --rm -v "$vname:/data" alpine cat /data/tx_bytes 2>/dev/null || echo "0")
            total_rx=$((total_rx + ${rx:-0}))
            total_tx=$((total_tx + ${tx:-0}))
        fi
    done
    echo "$total_rx $total_tx"
}

fix_volume_permissions() {
    local index=${1:-0}
    if [ "$index" -eq 0 ]; then
        for i in $(seq 1 $CONTAINER_COUNT); do
            local vname=$(get_volume_name $i)
            docker volume create "$vname" &>/dev/null || true
            docker run --rm -v "$vname:/data" alpine chown -R 1000:1000 /data 2>/dev/null || true
        done
    else
        local vname=$(get_volume_name $index)
        docker volume create "$vname" &>/dev/null || true
        docker run --rm -v "$vname:/data" alpine chown -R 1000:1000 /data 2>/dev/null || true
    fi
}

save_settings() {
    mkdir -p "$INSTALL_DIR"
    cat > "$INSTALL_DIR/settings.conf" << EOF
VERSION="$VERSION"
MAX_CLIENTS=$MAX_CLIENTS
BANDWIDTH=$BANDWIDTH
CONTAINER_COUNT=$CONTAINER_COUNT
CONTAINER_CPU_LIMIT="$CONTAINER_CPU_LIMIT"
CONTAINER_MEM_LIMIT="$CONTAINER_MEM_LIMIT"
CONTAINER_ULIMIT_NOFILE="$CONTAINER_ULIMIT_NOFILE"
SYSTEM_TUNED=${SYSTEM_TUNED}
DATA_CAP_GB=${DATA_CAP_GB}
DATA_CAP_PRIOR_USAGE=${DATA_CAP_PRIOR_USAGE}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED}
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY}
TELEGRAM_SERVER_LABEL="${TELEGRAM_SERVER_LABEL}"
EOF
    
    # Save per-container overrides if they exist
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        local cpu_var="CONTAINER_CPUS_${i}"
        local mem_var="CONTAINER_MEMORY_${i}"
        [ -n "${!mc_var:-}" ] && echo "${mc_var}=${!mc_var}" >> "$INSTALL_DIR/settings.conf"
        [ -n "${!bw_var:-}" ] && echo "${bw_var}=${!bw_var}" >> "$INSTALL_DIR/settings.conf"
        [ -n "${!cpu_var:-}" ] && echo "${cpu_var}=${!cpu_var}" >> "$INSTALL_DIR/settings.conf"
        [ -n "${!mem_var:-}" ] && echo "${mem_var}=${!mem_var}" >> "$INSTALL_DIR/settings.conf"
    done
    
    log_success "Settings saved"
}

save_settings_install() { save_settings; }

#═══════════════════════════════════════════════════════════════════════════
# v2.0 Infrastructure: Nginx Load Balancer
#═══════════════════════════════════════════════════════════════════════════

generate_nginx_conf() {
    local nginx_conf="/etc/nginx/nginx.conf"
    local stream_conf="/etc/nginx/stream.d/conduit.conf"
    
    log_info "Generating Nginx Layer 4 Load Balancer configuration..."
    mkdir -p /etc/nginx/stream.d
    
    if ! grep -q "include /etc/nginx/stream.d/\*.conf;" "$nginx_conf" 2>/dev/null; then
        cp "$nginx_conf" "${nginx_conf}.bak.$(date +%s)" 2>/dev/null || true
        if grep -q "^stream {" "$nginx_conf" 2>/dev/null; then
            sed -i '/^stream {/a\    include /etc/nginx/stream.d/*.conf;' "$nginx_conf"
        else
            sed -i '/^http {/i\stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' "$nginx_conf"
        fi
    fi
    
    cat > "$stream_conf" << 'NGINX_EOF'
# Psiphon Conduit Cluster Load Balancer v2.0

upstream conduit_tcp_backend {
    least_conn;
NGINX_EOF

    for i in $(seq 1 $CONTAINER_COUNT); do
        local backend_port=$((BACKEND_PORT_START + i - 1))
        echo "    server 127.0.0.1:${backend_port} max_fails=3 fail_timeout=30s;" >> "$stream_conf"
    done

    cat >> "$stream_conf" << 'NGINX_EOF'
}

upstream conduit_udp_backend {
    hash $remote_addr consistent;
NGINX_EOF

    for i in $(seq 1 $CONTAINER_COUNT); do
        local backend_port=$((BACKEND_PORT_START + i - 1))
        echo "    server 127.0.0.1:${backend_port} max_fails=3 fail_timeout=30s;" >> "$stream_conf"
    done

    cat >> "$stream_conf" << NGINX_EOF

}

server {
    listen ${NGINX_TCP_PORT};
    proxy_pass conduit_tcp_backend;
    proxy_timeout 10m;
    proxy_connect_timeout 30s;
}

server {
    listen ${NGINX_UDP_PORT_START}-${NGINX_UDP_PORT_END} udp;
    proxy_pass conduit_udp_backend;
    proxy_timeout 10m;
    proxy_responses 1;
}

error_log /var/log/nginx/conduit-stream-error.log warn;
access_log /var/log/nginx/conduit-stream-access.log;
NGINX_EOF

    log_success "Nginx configuration generated"
}

reload_nginx() {
    log_info "Testing Nginx configuration..."
    if nginx -t 2>&1 | tee /tmp/nginx-test.log; then
        log_info "Reloading Nginx..."
        systemctl reload nginx || systemctl restart nginx
        log_success "Nginx reloaded"
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
    fi
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
# v2.0 Infrastructure: System Tuning
#═══════════════════════════════════════════════════════════════════════════

tune_system() {
    if [ "$SYSTEM_TUNED" = "true" ]; then
        log_info "System already tuned (skipping)"
        return 0
    fi
    
    log_info "Applying kernel tuning for high-performance cluster..."
    sysctl -a > "$INSTALL_DIR/sysctl-backup-$(date +%s).txt" 2>/dev/null || true
    
    cat > /etc/sysctl.d/99-conduit-cluster.conf << 'SYSCTL_EOF'
# Conduit Cluster v2.0 Kernel Tuning
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
fs.file-max = 524288
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.netfilter.nf_conntrack_max = 262144
net.nf_conntrack_max = 262144
net.ipv4.tcp_mem = 786432 1048576 26777216
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10000 65535
SYSCTL_EOF

    if sysctl -p /etc/sysctl.d/99-conduit-cluster.conf; then
        log_success "Kernel tuning applied"
        SYSTEM_TUNED=true
        echo "SYSTEM_TUNED=true" >> "$INSTALL_DIR/settings.conf"
    else
        log_warning "Some sysctl settings failed (may require reboot)"
    fi
    
    if ! grep -q "conduit" /etc/security/limits.conf 2>/dev/null; then
        cat >> /etc/security/limits.conf << 'LIMITS_EOF'

# Conduit Cluster File Descriptor Limits
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
    
    local recommended_containers=$CONTAINER_COUNT
    if [ "$total_ram_mb" -lt 3500 ]; then
        recommended_containers=4
        log_warning "Low RAM. Recommending 4 containers max."
    elif [ "$total_ram_mb" -lt 7500 ]; then
        recommended_containers=8
        log_info "4GB RAM detected. Recommending 8 containers."
    elif [ "$total_ram_mb" -lt 15000 ]; then
        recommended_containers=16
        log_info "8-16GB RAM detected. You can run 16 containers."
    else
        recommended_containers=32
        log_info "High RAM detected. You can run 32+ containers."
    fi
    
    echo "  Recommended containers: ${recommended_containers}"
    echo ""
    
    if [ "$CONTAINER_COUNT" != "$recommended_containers" ] && [ "${INTERACTIVE:-true}" = "true" ]; then
        read -p "Use recommended container count (${recommended_containers})? [Y/n]: " use_rec < /dev/tty || true
        if [[ ! "$use_rec" =~ ^[Nn]$ ]]; then
            CONTAINER_COUNT=$recommended_containers
            log_success "Container count set to ${CONTAINER_COUNT}"
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 Infrastructure: Health Monitoring
#═══════════════════════════════════════════════════════════════════════════

generate_health_check_script() {
    log_info "Creating health check monitoring script..."
    
    cat > "$INSTALL_DIR/health-check.sh" << 'HEALTH_EOF'
#!/bin/bash
INSTALL_DIR="/opt/conduit"
LOG_FILE="$INSTALL_DIR/health-check.log"
ALERT_FILE="$INSTALL_DIR/health-alerts.log"
source "$INSTALL_DIR/settings.conf" 2>/dev/null || true

log_health() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }
send_alert() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALERT: $message" >> "$ALERT_FILE"
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ] && [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
        local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=🚨 *ALERT* [${server_label}]%0A%0A${message}" \
            -d "parse_mode=Markdown" &>/dev/null || true
    fi
}

if ! docker info &>/dev/null; then
    send_alert "Docker daemon not responding. Attempting restart..."
    systemctl restart docker
    sleep 5
    if ! docker info &>/dev/null; then
        send_alert "Docker restart failed. Manual intervention required."
        exit 1
    fi
    send_alert "Docker daemon restarted successfully"
fi

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

for i in $(seq 1 ${CONTAINER_COUNT:-8}); do
    if [ $i -eq 1 ]; then cname="conduit"; else cname="conduit-${i}"; fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
        send_alert "Container ${cname} not running. Attempting restart..."
        docker start "$cname" 2>/dev/null || {
            send_alert "Container ${cname} failed to start. Recreating..."
            /usr/local/bin/conduit start &>/dev/null
        }
    fi
    local restarts=$(docker inspect --format='{{.RestartCount}}' "$cname" 2>/dev/null || echo "0")
    if [ "$restarts" -gt 10 ]; then
        send_alert "Container ${cname} has ${restarts} restarts. Possible stability issue."
    fi
done

cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
mem_usage=$(free | awk '/Mem/{printf("%.1f"), $3/$2*100}')

if (( $(echo "$cpu_usage > 90" | bc -l) )); then
    send_alert "High CPU usage: ${cpu_usage}%"
fi

if (( $(echo "$mem_usage > 90" | bc -l) )); then
    send_alert "High memory usage: ${mem_usage}%"
fi

if dmesg -T | tail -100 | grep -i "killed process" | grep -i "conduit" &>/dev/null; then
    send_alert "OOM killer terminated a container. Consider increasing RAM or reducing containers."
fi

log_health "Health check completed: All systems operational"
HEALTH_EOF

    chmod 700 "$INSTALL_DIR/health-check.sh"
    log_success "Health check script created"
}

generate_nginx_watchdog() {
    log_info "Creating Nginx watchdog script..."
    
    cat > "$INSTALL_DIR/nginx-watchdog.sh" << 'WATCHDOG_EOF'
#!/bin/bash
if ! systemctl is-active nginx &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx down, restarting..." >> /opt/conduit/nginx-watchdog.log
    systemctl restart nginx
    source /opt/conduit/settings.conf 2>/dev/null || true
    if [ "${TELEGRAM_ENABLED:-false}" = "true" ] && [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
        local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=⚠️ Nginx watchdog restarted Nginx on ${server_label}" \
            -d "parse_mode=Markdown" &>/dev/null || true
    fi
fi
WATCHDOG_EOF

    chmod 700 "$INSTALL_DIR/nginx-watchdog.sh"
    log_success "Nginx watchdog script created"
}

setup_monitoring_cron() {
    log_info "Setting up monitoring cron jobs..."
    crontab -l 2>/dev/null | grep -v "conduit/health-check.sh" | grep -v "conduit/nginx-watchdog.sh" | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "# Conduit v2.0 Health Monitoring") | crontab -
    (crontab -l 2>/dev/null; echo "*/${HEALTH_CHECK_INTERVAL} * * * * /opt/conduit/health-check.sh") | crontab -
    (crontab -l 2>/dev/null; echo "*/${NGINX_WATCHDOG_INTERVAL} * * * * /opt/conduit/nginx-watchdog.sh") | crontab -
    log_success "Monitoring cron jobs configured"
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 Infrastructure: Container Management (Bridge Networking)
#═══════════════════════════════════════════════════════════════════════════

run_conduit_container() {
    local index=${1:-1}
    local cname=$(get_container_name $index)
    local vname=$(get_volume_name $index)
    local backend_port=$((BACKEND_PORT_START + index - 1))
    local mc=$(get_container_max_clients $index)
    local bw=$(get_container_bandwidth $index)
    local cpus=$(get_container_cpus $index)
    local mem=$(get_container_memory $index)
    
    docker volume create "$vname" &>/dev/null || true
    
    local docker_cmd="docker run -d --name \"$cname\" --restart unless-stopped"
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:443/tcp"
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:443/udp"
    docker_cmd="$docker_cmd -p 127.0.0.1:${backend_port}:16384-32768/udp"
    docker_cmd="$docker_cmd --cpus=\"${cpus}\""
    docker_cmd="$docker_cmd --memory=\"${mem}\""
    docker_cmd="$docker_cmd --ulimit nofile=${CONTAINER_ULIMIT_NOFILE}:${CONTAINER_ULIMIT_NOFILE}"
    docker_cmd="$docker_cmd -v \"$vname:/data\""
    docker_cmd="$docker_cmd \"$CONDUIT_IMAGE\" conduit --max-clients ${mc}"
    [ "$bw" != "-1" ] && docker_cmd="$docker_cmd --bandwidth ${bw}"
    
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
    fix_volume_permissions
    local success_count=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        if run_conduit_container $i; then
            success_count=$((success_count + 1))
        fi
        sleep 2
    done
    
    if [ $success_count -eq $CONTAINER_COUNT ]; then
        log_success "All ${CONTAINER_COUNT} containers started"
        return 0
    elif [ $success_count -gt 0 ]; then
        log_warning "${success_count}/${CONTAINER_COUNT} containers started"
        return 1
    else
        log_error "Failed to start any containers"
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════════
# v2.0 Infrastructure: Optimized Tracker (Single-Interface)
#═══════════════════════════════════════════════════════════════════════════

detect_primary_interface() {
    local primary_if=$(ip route | grep default | head -1 | awk '{print $5}')
    if [ -z "$primary_if" ]; then
        primary_if=$(ip link show | grep -E "^[0-9]+: (eth|ens|enp)" | head -1 | awk -F': ' '{print $2}')
    fi
    echo "$primary_if"
}

generate_tracker_script() {
    log_info "Generating optimized tracker script..."
    local primary_interface=$(detect_primary_interface)
    
    if [ -z "$primary_interface" ]; then
        log_warning "Could not detect primary interface. Using eth0."
        primary_interface="eth0"
    fi
    
    log_info "Primary interface: ${primary_interface}"
    
    cat > "$INSTALL_DIR/conduit-tracker.sh" << 'TRACKER_EOF'
#!/bin/bash
PERSIST_DIR="/opt/conduit/traffic_stats"
SNAPSHOT_FILE="$PERSIST_DIR/tracker_snapshot"
CUMULATIVE_DATA="$PERSIST_DIR/cumulative_data"
CUMULATIVE_IPS="$PERSIST_DIR/cumulative_ips"
GEOIP_CACHE="$PERSIST_DIR/geoip_cache"
PRIMARY_INTERFACE="PRIMARY_INTERFACE_PLACEHOLDER"

mkdir -p "$PERSIST_DIR"
touch "$CUMULATIVE_DATA" "$CUMULATIVE_IPS" "$GEOIP_CACHE" "$SNAPSHOT_FILE"

get_country() {
    local ip="$1"
    if echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.)'; then
        echo "LOCAL"
        return
    fi
    local cached=$(grep "^${ip}|" "$GEOIP_CACHE" 2>/dev/null | cut -d'|' -f2)
    if [ -n "$cached" ]; then echo "$cached"; return; fi
    local country="Unknown"
    if command -v geoiplookup &>/dev/null; then
        country=$(geoiplookup "$ip" 2>/dev/null | awk -F': ' '{print $2}' | cut -d',' -f1 | head -1)
    elif command -v mmdblookup &>/dev/null; then
        country=$(mmdblookup --file /usr/share/GeoIP/GeoLite2-Country.mmdb --ip "$ip" country names en 2>/dev/null | grep -oP '"\K[^"]+' | head -1)
    fi
    [ -z "$country" ] && country="Unknown"
    echo "${ip}|${country}" >> "$GEOIP_CACHE"
    echo "$country"
}

while true; do
    timeout 15 tcpdump -i "$PRIMARY_INTERFACE" -nn -q -t -l 'tcp or udp and not port 22' 2>/dev/null | \
    awk -v snapshot="$SNAPSHOT_FILE" -v cumulative="$CUMULATIVE_DATA" -v ips="$CUMULATIVE_IPS" '
    {
        match($0, /([0-9]{1,3}\.){3}[0-9]{1,3}/)
        src_ip = substr($0, RSTART, RLENGTH)
        match($0, /> ([0-9]{1,3}\.){3}[0-9]{1,3}/)
        dst_ip = substr($0, RSTART+2, RLENGTH-2)
        if (match($0, /length [0-9]+/)) len = substr($0, RSTART+7, RLENGTH-7); else len = 0
        if (src_ip != "" && dst_ip != "") {
            if (src_ip ~ /^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.)/) {
                out[dst_ip] += len
                all_ips[dst_ip] = 1
            } else {
                in[src_ip] += len
                all_ips[src_ip] = 1
            }
        }
    }
    END {
        for (ip in all_ips) {
            print ip "|" in[ip] "|" out[ip] >> snapshot ".tmp"
        }
    }
    ' && mv "$SNAPSHOT_FILE.tmp" "$SNAPSHOT_FILE" 2>/dev/null || true
    
    if [ -s "$SNAPSHOT_FILE" ]; then
        while IFS='|' read -r ip bytes_in bytes_out; do
            [ -z "$ip" ] && continue
            country=$(get_country "$ip")
            if ! grep -q "^${ip}|" "$CUMULATIVE_IPS" 2>/dev/null; then
                echo "${ip}|${country}" >> "$CUMULATIVE_IPS"
            fi
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

    sed -i "s/PRIMARY_INTERFACE_PLACEHOLDER/${primary_interface}/g" "$INSTALL_DIR/conduit-tracker.sh"
    chmod 700 "$INSTALL_DIR/conduit-tracker.sh"
    log_success "Tracker script generated"
}

regenerate_tracker_script() { generate_tracker_script; }

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
# Dashboard Functions (Multi-Container Aggregation)
#═══════════════════════════════════════════════════════════════════════════

show_status() {
    local mode="${1:-normal}"
    local EL=""
    [ "$mode" == "live" ] && EL="\033[K"
    
    echo ""
    local docker_ps_cache=$(docker ps 2>/dev/null)
    local running_count=0
    declare -A _c_running _c_conn _c_cing _c_up _c_down
    local total_connecting=0
    local total_connected=0
    local uptime=""
    
    local _st_tmpdir=$(mktemp -d /tmp/.conduit_st.XXXXXX)
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        _c_running[$i]=false
        _c_conn[$i]="0"
        _c_cing[$i]="0"
        _c_up[$i]=""
        _c_down[$i]=""
        if echo "$docker_ps_cache" | grep -q "[[:space:]]${cname}$"; then
            _c_running[$i]=true
            running_count=$((running_count + 1))
            ( docker logs --tail 30 "$cname" 2>&1 | grep "\[STATS\]" | tail -1 > "$_st_tmpdir/logs_${i}" ) &
        fi
    done
    wait
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ "${_c_running[$i]}" = true ] && [ -f "$_st_tmpdir/logs_${i}" ]; then
            local logs=$(cat "$_st_tmpdir/logs_${i}")
            if [ -n "$logs" ]; then
                IFS='|' read -r c_connecting c_connected c_up_val c_down_val c_uptime_val <<< $(echo "$logs" | awk '{
                    cing=0; conn=0; up=""; down=""; ut=""
                    for(j=1;j<=NF;j++){
                        if($j=="Connecting:") cing=$(j+1)+0
                        else if($j=="Connected:") conn=$(j+1)+0
                        else if($j=="Up:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Down:/)break; up=up (up?" ":"") $k}}
                        else if($j=="Down:"){for(k=j+1;k<=NF;k++){if($k=="|"||$k~/Uptime:/)break; down=down (down?" ":"") $k}}
                        else if($j=="Uptime:"){for(k=j+1;k<=NF;k++){ut=ut (ut?" ":"") $k}}
                    }
                    printf "%d|%d|%s|%s|%s", cing, conn, up, down, ut
                }')
                _c_conn[$i]="${c_connected:-0}"
                _c_cing[$i]="${c_connecting:-0}"
                _c_up[$i]="${c_up_val}"
                _c_down[$i]="${c_down_val}"
                total_connecting=$((total_connecting + ${c_connecting:-0}))
                total_connected=$((total_connected + ${c_connected:-0}))
                [ -z "$uptime" ] && uptime="${c_uptime_val}"
            fi
        fi
    done
    rm -rf "$_st_tmpdir"
    
    local connecting=$total_connecting
    local connected=$total_connected
    _total_connected=$total_connected
    
    local upload="" download=""
    local total_up_bytes=0 total_down_bytes=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        if [ -n "${_c_up[$i]}" ]; then
            local bytes=$(echo "${_c_up[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_up_bytes=$((total_up_bytes + ${bytes:-0}))
        fi
        if [ -n "${_c_down[$i]}" ]; then
            local bytes=$(echo "${_c_down[$i]}" | awk '{
                val=$1; unit=toupper($2)
                if (unit ~ /^KB/) val*=1024
                else if (unit ~ /^MB/) val*=1048576
                else if (unit ~ /^GB/) val*=1073741824
                else if (unit ~ /^TB/) val*=1099511627776
                printf "%.0f", val
            }')
            total_down_bytes=$((total_down_bytes + ${bytes:-0}))
        fi
    done
    
    [ "$total_up_bytes" -gt 0 ] && upload=$(format_bytes $total_up_bytes)
    [ "$total_down_bytes" -gt 0 ] && download=$(format_bytes $total_down_bytes)
    
    if [ "$running_count" -gt 0 ]; then
        local _rs_tmpdir=$(mktemp -d /tmp/.conduit_rs.XXXXXX)
        ( get_container_stats > "$_rs_tmpdir/cstats" ) &
        ( get_system_stats > "$_rs_tmpdir/sys" ) &
        ( get_net_speed > "$_rs_tmpdir/net" ) &
        wait
        
        local stats=$(cat "$_rs_tmpdir/cstats" 2>/dev/null)
        local sys_stats=$(cat "$_rs_tmpdir/sys" 2>/dev/null)
        local net_speed=$(cat "$_rs_tmpdir/net" 2>/dev/null)
        rm -rf "$_rs_tmpdir"
        
        local raw_app_cpu=$(echo "$stats" | awk '{print $1}' | tr -d '%')
        local num_cores=$(get_cpu_cores)
        local app_cpu="0%" app_cpu_display=""
        
        if [[ "$raw_app_cpu" =~ ^[0-9.]+$ ]]; then
            app_cpu=$(awk -v cpu="$raw_app_cpu" -v cores="$num_cores" 'BEGIN {printf "%.2f%%", cpu / cores}')
            if [ "$num_cores" -gt 1 ]; then
                app_cpu_display="${app_cpu} (${raw_app_cpu}% vCPU)"
            else
                app_cpu_display="${app_cpu}"
            fi
        else
            app_cpu="${raw_app_cpu}%"
            app_cpu_display="${app_cpu}"
        fi
        
        local app_ram=$(echo "$stats" | awk '{print $2, $3, $4}')
        local sys_cpu=$(echo "$sys_stats" | awk '{print $1}')
        local sys_ram_used=$(echo "$sys_stats" | awk '{print $2}')
        local sys_ram_total=$(echo "$sys_stats" | awk '{print $3}')
        local rx_mbps=$(echo "$net_speed" | awk '{print $1}')
        local tx_mbps=$(echo "$net_speed" | awk '{print $2}')
        local net_display="↓ ${rx_mbps} Mbps  ↑ ${tx_mbps} Mbps"
        
        if [ -n "$upload" ] || [ "$connected" -gt 0 ] || [ "$connecting" -gt 0 ]; then
            local status_line="${BOLD}Status:${NC} ${GREEN}Running${NC}"
            [ -n "$uptime" ] && status_line="${status_line} (${uptime})"
            echo -e "${status_line}${EL}"
            echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}    Clients: ${GREEN}${connected}${NC} connected, ${YELLOW}${connecting}${NC} connecting${EL}"
            echo -e "${EL}"
            echo -e "${CYAN}═══ Traffic (current session) ═══${NC}${EL}"
            [ -n "$upload" ] && echo -e "  Upload:       ${CYAN}${upload}${NC}${EL}"
            [ -n "$download" ] && echo -e "  Download:     ${CYAN}${download}${NC}${EL}"
            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
        else
            echo -e "${BOLD}Status:${NC} ${GREEN}Running${NC}${EL}"
            echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}${EL}"
            echo -e "${EL}"
            echo -e "${CYAN}═══ Resource Usage ═══${NC}${EL}"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "App:" "$app_cpu_display" "$app_ram"
            printf "  %-8s CPU: ${YELLOW}%-20s${NC} | RAM: ${YELLOW}%-20s${NC}${EL}\n" "System:" "$sys_cpu" "$sys_ram_used / $sys_ram_total"
            printf "  %-8s Net: ${YELLOW}%-43s${NC}${EL}\n" "Total:" "$net_display"
            echo -e "${EL}"
            echo -e "  Stats:        ${YELLOW}Waiting for first stats...${NC}${EL}"
        fi
    else
        echo -e "${BOLD}Status:${NC} ${RED}Stopped${NC}${EL}"
    fi
    
    echo -e "${EL}"
    echo -e "${CYAN}═══ SETTINGS ═══${NC}${EL}"
    local has_overrides=false
    for i in $(seq 1 $CONTAINER_COUNT); do
        local mc_var="MAX_CLIENTS_${i}"
        local bw_var="BANDWIDTH_${i}"
        if [ -n "${!mc_var:-}" ] || [ -n "${!bw_var:-}" ]; then
            has_overrides=true
            break
        fi
    done
    
    if [ "$has_overrides" = true ]; then
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
        for i in $(seq 1 $CONTAINER_COUNT); do
            local mc=$(get_container_max_clients $i)
            local bw=$(get_container_bandwidth $i)
            local bw_d="Unlimited"
            [ "$bw" != "-1" ] && bw_d="${bw} Mbps"
            printf "  %-12s clients: %-5s bw: %s${EL}\n" "$(get_container_name $i)" "$mc" "$bw_d"
        done
    else
        echo -e "  Max Clients:  ${MAX_CLIENTS}${EL}"
        if [ "$BANDWIDTH" == "-1" ]; then
            echo -e "  Bandwidth:    Unlimited${EL}"
        else
            echo -e "  Bandwidth:    ${BANDWIDTH} Mbps${EL}"
        fi
        echo -e "  Containers:   ${CONTAINER_COUNT}${EL}"
    fi
    
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        echo -e "  Data Cap:     $(format_gb $total_used) / ${DATA_CAP_GB} GB${EL}"
    fi
    
    echo -e "${EL}"
    echo -e "${CYAN}═══ AUTO-START SERVICE ═══${NC}${EL}"
    if command -v systemctl &>/dev/null && systemctl is-enabled conduit.service 2>/dev/null | grep -q "enabled"; then
        echo -e "  Auto-start:   ${GREEN}Enabled (systemd)${NC}${EL}"
        local svc_containers=$(docker ps --filter "name=^conduit" --format '{{.Names}}' 2>/dev/null | wc -l)
        if [ "${svc_containers:-0}" -gt 0 ]; then
            echo -e "  Service:      ${GREEN}active${NC}${EL}"
        else
            echo -e "  Service:      ${YELLOW}inactive${NC}${EL}"
        fi
    else
        echo -e "  Auto-start:   ${YELLOW}Not configured${NC}${EL}"
    fi
    
    if is_tracker_active; then
        echo -e "  Tracker:      ${GREEN}Active${NC}${EL}"
    else
        echo -e "  Tracker:      ${YELLOW}Inactive${NC}${EL}"
    fi
    echo -e "${EL}"
}

show_dashboard() {
    clear
    print_header
    show_status
}

show_logs() {
    clear
    print_header
    echo -e "${CYAN}═══ DOCKER LOGS ═══${NC}"
    echo ""
    
    if [ "$CONTAINER_COUNT" -eq 1 ]; then
        echo "Viewing logs for conduit..."
        echo ""
        docker logs --tail 100 -f conduit 2>&1
    else
        echo "Select container:"
        for i in $(seq 1 $CONTAINER_COUNT); do
            local cname=$(get_container_name $i)
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
                echo "  ${i}. ${cname} ${GREEN}(running)${NC}"
            else
                echo "  ${i}. ${cname} ${RED}(stopped)${NC}"
            fi
        done
        echo "  a. All containers (combined)"
        echo "  0. Back"
        echo ""
        read -p "Choice: " log_choice < /dev/tty || return
        
        case "$log_choice" in
            0) return ;;
            a)
                echo "Viewing combined logs..."
                echo ""
                for i in $(seq 1 $CONTAINER_COUNT); do
                    docker logs --tail 20 "$(get_container_name $i)" 2>&1 | sed "s/^/[$(get_container_name $i)] /"
                done | tail -100
                ;;
            [1-9]|[1-9][0-9])
                if [ "$log_choice" -le "$CONTAINER_COUNT" ]; then
                    local cname=$(get_container_name $log_choice)
                    echo "Viewing logs for ${cname}..."
                    echo ""
                    docker logs --tail 100 -f "$cname" 2>&1
                else
                    echo -e "${RED}Invalid selection${NC}"
                fi
                ;;
            *)
                echo -e "${RED}Invalid selection${NC}"
                ;;
        esac
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}

#═══════════════════════════════════════════════════════════════════════════
# Container Lifecycle Management
#═══════════════════════════════════════════════════════════════════════════

start_conduit() {
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        local cap_bytes=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        if [ "$total_used" -ge "$cap_bytes" ]; then
            echo -e "${RED}⚠ Data cap exceeded. Containers will not start.${NC}"
            return 1
        fi
    fi
    
    echo "Starting Conduit ($CONTAINER_COUNT container(s))..."
    
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)
        
        if docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
                echo -e "${GREEN}✓ ${name} already running${NC}"
                continue
            fi
            echo "Recreating ${name}..."
            docker rm "$name" 2>/dev/null || true
        fi
        
        docker volume create "$vol" 2>/dev/null || true
        fix_volume_permissions $i
        run_conduit_container $i
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ ${name} started${NC}"
        else
            echo -e "${RED}✗ Failed to start ${name}${NC}"
        fi
    done
    
    setup_tracker_service 2>/dev/null || true
    
    # Regenerate Nginx config if needed
    if command -v nginx &>/dev/null; then
        generate_nginx_conf
        reload_nginx
    fi
    
    return 0
}

stop_conduit() {
    echo "Stopping Conduit..."
    local stopped=0
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker stop "$name" 2>/dev/null
            echo -e "${YELLOW}✓ ${name} stopped${NC}"
            stopped=$((stopped + 1))
        fi
    done
    [ "$stopped" -eq 0 ] && echo -e "${YELLOW}No containers running${NC}"
    stop_tracker_service 2>/dev/null || true
    return 0
}

restart_conduit() {
    if [ "$DATA_CAP_GB" -gt 0 ] 2>/dev/null; then
        local usage=$(get_data_usage)
        local used_rx=$(echo "$usage" | awk '{print $1}')
        local used_tx=$(echo "$usage" | awk '{print $2}')
        local total_used=$((used_rx + used_tx + ${DATA_CAP_PRIOR_USAGE:-0}))
        local cap_bytes=$(awk -v gb="$DATA_CAP_GB" 'BEGIN{printf "%.0f", gb * 1073741824}')
        if [ "$total_used" -ge "$cap_bytes" ]; then
            echo -e "${RED}⚠ Data cap exceeded. Cannot restart.${NC}"
            return 1
        fi
    fi
    
    echo "Restarting Conduit ($CONTAINER_COUNT container(s))..."
    for i in $(seq 1 $CONTAINER_COUNT); do
        local name=$(get_container_name $i)
        local vol=$(get_volume_name $i)
        
        if docker ps 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker restart "$name" 2>/dev/null
            echo -e "${GREEN}✓ ${name} restarted${NC}"
        elif docker ps -a 2>/dev/null | grep -q "[[:space:]]${name}$"; then
            docker start "$name" 2>/dev/null
            echo -e "${GREEN}✓ ${name} started${NC}"
        else
            docker volume create "$vol" 2>/dev/null || true
            fix_volume_permissions $i
            run_conduit_container $i
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ ${name} created${NC}"
            else
                echo -e "${RED}✗ Failed to create ${name}${NC}"
            fi
        fi
    done
    
    setup_tracker_service 2>/dev/null || true
    return 0
}

#═══════════════════════════════════════════════════════════════════════════
# Interactive Menu System
#═══════════════════════════════════════════════════════════════════════════

show_menu() {
    # Auto-fix systemd service files
    if command -v systemctl &>/dev/null; then
        local need_reload=false
        if [ -f /etc/systemd/system/conduit.service ]; then
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
                need_reload=true
            fi
        fi
        
        if [ "$need_reload" = true ]; then
            systemctl daemon-reload 2>/dev/null || true
            systemctl reset-failed conduit.service 2>/dev/null || true
            systemctl enable conduit.service 2>/dev/null || true
        fi
    fi
    
    # Auto-start/upgrade tracker if containers running
    local any_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c "^conduit" || true)
    if [ "${any_running