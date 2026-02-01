#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║    🚀 PSIPHON CONDUIT CLUSTER v2.1 - IRAN OPTIMIZED EDITION      ║
# ║                                                                   ║
# ║  • Nginx Layer 4 Load Balancing (Ports 443, 80, 8080, 2053)       ║
# ║  • Iran-Specific DPI Circumvention (MTU 1380, sysctl tuning)      ║
# ║  • High-Performance Bridge Networking                             ║
# ║  • Automated Resource Scaling                                     ║
# ╚═══════════════════════════════════════════════════════════════════╝
#
# Usage:
# curl -sL https://raw.githubusercontent.com/tondhoosh/CONDUIT-CLUSTER-MANAGER/main/conduit-cluster-v2.1-iran.sh | sudo bash
#

set -eo pipefail

# ==============================================================================
# CONFIGURATION
# ==============================================================================

VERSION="2.1-iran"
INSTALL_DIR="/opt/conduit"
DATA_DIR="/data" # Internal container path
HOST_DATA_PREFIX="conduit-data-"

# Image Configuration
CONDUIT_IMAGE="ghcr.io/psiphon-inc/conduit/cli:latest"

# Iran Optimization Defaults
MTU_SIZE=1380
TCP_FRTO=2
TCP_MTU_PROBING=1

# Container Resources (Safe defaults for 4GB VPS)
CONTAINER_CPU="0.1"
CONTAINER_MEM="256m"
CONTAINER_MAX_CLIENTS=1000
CONTAINER_BANDWIDTH=-1  # Unlimited

# Nginx Load Balancer Ports (DPI Bypass Diversity)
LB_PORTS=(443 80 8080 8880 2053)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root"
        exit 1
    fi
}

detect_resources() {
    # Auto-calculate max containers based on RAM
    # Reserve 1GB for system + Nginx, use rest for containers (256MB each)
    local total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local available_for_containers=$((total_ram_mb - 1024))
    
    if [ $available_for_containers -le 0 ]; then
        available_for_containers=512 # Fallback minimal
    fi
    
    # Conservative calculation: 256MB per container
    local max_safe=$((available_for_containers / 256))
    
    # Cap at 12 for 4GB VPS stability (user verified)
    if [ $max_safe -gt 12 ]; then
        RECOMMENDED_CONTAINERS=12
    else
        RECOMMENDED_CONTAINERS=$max_safe
    fi
    
    # Minimum 1
    [ "$RECOMMENDED_CONTAINERS" -lt 1 ] && RECOMMENDED_CONTAINERS=1
}

# ==============================================================================
# IRAN OPTIMIZATION ENGINE
# ==============================================================================

tune_system_iran() {
    log_info "Applying Iran-specific network optimizations..."
    
    # Backup sysctl
    if [ ! -f /etc/sysctl.conf.bak ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    # 1. Packet Loss & High Latency Tuning
    # tcp_frto=2: Aggressive Retransmission Timeout (Essential for lossy mobile networks)
    sysctl -w net.ipv4.tcp_frto=$TCP_FRTO >/dev/null
    
    # tcp_mtu_probing=1: Black hole router detection (Fixes MTU issues on Irancell/MCI)
    sysctl -w net.ipv4.tcp_mtu_probing=$TCP_MTU_PROBING >/dev/null

    # 2. Buffer Tuning for High Concurrency
    sysctl -w net.core.netdev_max_backlog=100000 >/dev/null
    sysctl -w net.core.rmem_max=67108864 >/dev/null
    sysctl -w net.core.wmem_max=67108864 >/dev/null
    sysctl -w net.ipv4.udp_rmem_min=16384 >/dev/null
    sysctl -w net.ipv4.udp_wmem_min=16384 >/dev/null
    
    # 3. Congestion Control (BBR is best for throughput, but cubic potentially more stable on erratic links)
    # We'll stick to BBR if available, otherwise cubic
    if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
        sysctl -w net.core.default_qdisc=fq >/dev/null
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null
    fi

    # 4. Persistence
    cat > /etc/sysctl.d/99-conduit-iran.conf <<EOF
net.ipv4.tcp_frto=$TCP_FRTO
net.ipv4.tcp_mtu_probing=$TCP_MTU_PROBING
net.core.netdev_max_backlog=100000
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
EOF
    sysctl --system >/dev/null
    log_success "Network stack optimized for high-loss environment"
}

set_mtu_optimization() {
    log_info "Optimizing MTU for DPI Circumvention..."
    
    local iface=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
    
    if [ -z "$iface" ]; then
        log_warn "Could not detect potential WAN interface. Skipping MTU."
        return
    fi
    
    # Set MTU to 1380 to prevent DPI fragmentation attacks
    ip link set dev "$iface" mtu $MTU_SIZE || true
    log_success "MTU set to $MTU_SIZE on interface $iface"
    
    # Make persistent via Netplan or Interfaces if possible (simple approach for now)
    # Most cloud-init resets this on reboot, so we add a cron/rc.local ensure
    if ! grep -q "ip link set dev $iface mtu $MTU_SIZE" /etc/rc.local 2>/dev/null; then
         # Ensure rc.local exists and is executable
         if [ ! -f /etc/rc.local ]; then
             echo '#!/bin/bash' > /etc/rc.local
             echo "exit 0" >> /etc/rc.local
             chmod +x /etc/rc.local
         fi
         # Insert before exit 0
         sed -i "/exit 0/i ip link set dev $iface mtu $MTU_SIZE" /etc/rc.local
    fi
}

# ==============================================================================
# NGINX LOAD BALANCER
# ==============================================================================

install_nginx() {
    if ! command -v nginx &>/dev/null; then
        log_info "Installing Nginx for Layer 4 Load Balancing..."
        apt-get update -qq
        apt-get install -y nginx -qq
    fi
    
    # Ensure stream module is available (standard in ubuntu nginx package)
    if [ ! -d /etc/nginx/modules-enabled ]; then
        mkdir -p /etc/nginx/modules-enabled
    fi
}

setup_nginx_lb() {
    local count=$1
    log_info "Configuring Nginx Layer 4 Load Balancer for $count containers..."
    
    # Backup existing config
    [ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%s)
    
    # Create stream configuration
    local stream_conf="/etc/nginx/streams_conduit.conf"
    
    cat > "$stream_conf" <<EOF
upstream conduit_backend {
    hash \$remote_addr consistent;
EOF

    # Add upstream servers (localhost:10001, 10002, etc.)
    for i in $(seq 1 $count); do
        local port=$((10000 + i))
        echo "    server 127.0.0.1:$port max_fails=3 fail_timeout=30s;" >> "$stream_conf"
    done

    cat >> "$stream_conf" <<EOF
}

server {
    # Anti-Probe / Anti-Freeze Settings
    proxy_timeout 60s;
    proxy_connect_timeout 10s;
    
    proxy_pass conduit_backend;

    # Multi-Port Diversity with reuseport for performance
EOF

    # Add listeners for all defined ports
    for port in "${LB_PORTS[@]}"; do
        echo "    listen $port reuseport;" >> "$stream_conf"
        echo "    listen $port udp reuseport;" >> "$stream_conf"
    done

    echo "}" >> "$stream_conf"
    
    # Inject stream include into main nginx.conf if not present
    if ! grep -q "streams_conduit.conf" /etc/nginx/nginx.conf; then
        # Append stream block at the end of nginx.conf
        echo "" >> /etc/nginx/nginx.conf
        echo "stream { include /etc/nginx/streams_conduit.conf; }" >> /etc/nginx/nginx.conf
    fi
    
    # Test and Reload
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        log_success "Nginx Load Balancer active on ports: ${LB_PORTS[*]}"
    else
        log_error "Nginx configuration failed. Reverting..."
        cp /etc/nginx/nginx.conf.bak* /etc/nginx/nginx.conf
        nginx -t
    fi
}

# ==============================================================================
# CONTAINER MANAGEMENT
# ==============================================================================

deploy_cluster() {
    local target_count=$1
    
    log_info "Deploying $target_count optimized containers..."
    
    # Stop existing containers if scaling down or refreshing
    local running=$(docker ps -q --filter "name=conduit" | wc -l)
    if [ "$running" -gt 0 ]; then
        log_info "Stopping existing containers..."
        docker ps -q --filter "name=conduit" | xargs -r docker stop >/dev/null
        docker ps -a -q --filter "name=conduit" | xargs -r docker rm >/dev/null
    fi
    
    for i in $(seq 1 $target_count); do
        local name="conduit-$i"
        [ "$i" -eq 1 ] && name="conduit" # Keep legacy name for first one
        
        local port=$((10000 + i))
        local vol="conduit-data-$i"
        [ "$i" -eq 1 ] && vol="conduit-data"
        
        # Ensure volume and permissions
        docker volume create "$vol" >/dev/null
        docker run --rm -v "$vol:/data" alpine chmod 777 /data >/dev/null
        
        # Run Container (Bridge Mode + Port Mapping)
        docker run -d \
            --name "$name" \
            --restart unless-stopped \
            -p 127.0.0.1:$port:8080 \
            -p 127.0.0.1:$port:8080/udp \
            --cpus="$CONTAINER_CPU" \
            --memory="$CONTAINER_MEM" \
            --ulimit nofile=100000:100000 \
            -v "$vol:/data" \
            "$CONDUIT_IMAGE" \
            start -d /data --max-clients $CONTAINER_MAX_CLIENTS --bandwidth $CONTAINER_BANDWIDTH --stats-file >/dev/null
            
        echo -n "."
    done
    echo ""
    log_success "Cluster deployment complete!"
}

# ==============================================================================
# DASHBOARD & MENU
# ==============================================================================

show_dashboard() {
    clear
    local container_count=$(docker ps -q --filter "name=conduit" | wc -l)
    local nginx_status=$(systemctl is-active nginx)
    
    # Aggregate Stats
    local total_clients=0
    local total_up=0
    local total_down=0
    
    # Quick grep of all stats files
    # This loop might be slow for 40 containers, but okay for 12
    for i in $(seq 1 $container_count); do
        local name="conduit-$i"
        [ "$i" -eq 1 ] && name="conduit"
        
        if stats=$(docker exec $name cat /data/stats.json 2>/dev/null); then
             # Extract with grep/cut avoids jq dependency
             local c=$(echo "$stats" | grep -o '"connectedClients": *[0-9]*' | cut -d: -f2 | tr -d ' ,')
             local u=$(echo "$stats" | grep -o '"totalBytesUp": *[0-9]*' | cut -d: -f2 | tr -d ' ,')
             local d=$(echo "$stats" | grep -o '"totalBytesDown": *[0-9]*' | cut -d: -f2 | tr -d ' ,')
             
             total_clients=$((total_clients + ${c:-0}))
             total_up=$((total_up + ${u:-0}))
             total_down=$((total_down + ${d:-0}))
        fi
    done
    
    # Format Bytes
    local up_gb=$(awk "BEGIN {printf \"%.2f\", $total_up/1024/1024/1024}")
    local down_gb=$(awk "BEGIN {printf \"%.2f\", $total_down/1024/1024/1024}")

    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    🚀 CONDUIT CLUSTER v${VERSION} - IRAN OPTIMIZED               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Cluster Status:${NC}   $container_count Containers Running"
    echo -e "  ${BOLD}Load Balancer:${NC}    $nginx_status (Ports: ${LB_PORTS[*]})"
    echo -e "  ${BOLD}Optimization:${NC}     MTU $MTU_SIZE / TCP FRTO 2"
    echo ""
    echo -e "  ${GREEN}Connected Clients:${NC} ${BOLD}$total_clients${NC}"
    echo -e "  ${YELLOW}Total Traffic:${NC}     ↑ $up_gb GB   ↓ $down_gb GB"
    echo ""
    echo -e "  ${DIM}Press Enter for Menu...${NC}"
    read -r
}

main_menu() {
    while true; do
        clear
        echo -e "${CYAN}MAIN MENU${NC}"
        echo "1. 📊 View Cluster Dashboard"
        echo "2. 🔄 Deploy/Update Cluster"
        echo "3. 🛠️  Re-Apply Iran Optimizations (Sysctl/MTU)"
        echo "4. 🩺 Health Check"
        echo "0. 🚪 Exit"
        echo ""
        read -p "Select option: " choice
        
        case $choice in
            1) show_dashboard ;;
            2) 
                detect_resources
                read -p "How many containers to deploy? (Recommended: $RECOMMENDED_CONTAINERS): " target
                target=${target:-$RECOMMENDED_CONTAINERS}
                tune_system_iran
                set_mtu_optimization
                install_nginx
                deploy_cluster $target
                setup_nginx_lb $target
                read -p "Press Enter to continue..."
                ;;
            3)
                tune_system_iran
                set_mtu_optimization
                log_success "Optimizations reapplied"
                sleep 2
                ;;
            4)
                echo "Running health check..."
                # Quick Nginx Check
                nginx -t
                # Quick Container Check
                docker ps --filter "name=conduit" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
                read -p "Press Enter to continue..."
                ;;
            0) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# ==============================================================================
# ENTRY POINT
# ==============================================================================

check_root
detect_resources

# Arguments support for non-interactive
if [ "$1" == "deploy" ]; then
    tune_system_iran
    set_mtu_optimization
    install_nginx
    deploy_cluster $RECOMMENDED_CONTAINERS
    setup_nginx_lb $RECOMMENDED_CONTAINERS
    exit 0
fi

# Interactive Menu
main_menu
