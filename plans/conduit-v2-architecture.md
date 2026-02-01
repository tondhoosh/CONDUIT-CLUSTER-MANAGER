# Psiphon Conduit Manager - High-Performance Cluster Edition v2.0

## Architecture Upgrade Plan

### Executive Summary
Upgrade the existing Conduit Manager (v1.2) to support 40,000 concurrent users through:
- **Nginx Layer 4 Load Balancer** replacing direct host networking
- **40 backend containers** (default) vs current 5 max
- **System-level tuning** for high-concurrency workloads
- **Optimized single-interface traffic tracking**
- **Aggregated dashboard metrics**

---

## 1. Current Architecture Analysis

### 1.1 Existing Components
```
┌─────────────────────────────────────────────────────────┐
│                     Host System                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Docker Containers (1-5) with --network host     │   │
│  │  • conduit (ports 443, 5566)                     │   │
│  │  • conduit-2, conduit-3, conduit-4, conduit-5    │   │
│  │  Each binds directly to host ports              │   │
│  └──────────────────────────────────────────────────┘   │
│  ┌──────────────────────────────────────────────────┐   │
│  │  Background Tracker (systemd service)            │   │
│  │  • tcpdump -ni any                               │   │
│  │  • Monitors traffic across all interfaces       │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### 1.2 Current Limitations
- **Scaling**: Hard-coded MAX_CONTAINERS=5
- **Port Conflicts**: All containers use `--network host`, only first container gets ports 443/5566
- **Resource Limits**: No ulimit enforcement per container
- **System Tuning**: No kernel parameter optimization
- **Tracker Inefficiency**: Monitors "any" interface including container internals

---

## 2. High-Performance Cluster Edition v2.0 Architecture

### 2.1 New Architecture Diagram
```
┌──────────────────────────────────────────────────────────────────┐
│                         Host System                               │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Nginx Layer 4 Load Balancer                   │  │
│  │  • Listens: 0.0.0.0:443 (TCP/UDP) reuseport               │  │
│  │  • Listens: 0.0.0.0:5566 (TCP/UDP) reuseport              │  │
│  │  • Upstreams: 127.0.0.1:8081-8120 (40 backends)           │  │
│  │  • Algorithm: least_conn (TCP), hash (UDP)                │  │
│  └────────────────────────────────────────────────────────────┘  │
│               ▼                          ▼                        │
│  ┌─────────────────────┐    ┌─────────────────────┐              │
│  │  Backend Containers (Default: 40)               │              │
│  │  • conduit-1:  127.0.0.1:8081                   │              │
│  │  • conduit-2:  127.0.0.1:8082                   │              │
│  │  • ...                                          │              │
│  │  • conduit-40: 127.0.0.1:8120                   │              │
│  │                                                  │              │
│  │  Each container:                                │              │
│  │  - Bridge network mode                          │              │
│  │  - Port mapping: 127.0.0.1:808X→443,5566        │              │
│  │  - ulimit nofile=65535:65535                    │              │
│  │  - Resource limits: --cpus, --memory            │              │
│  └─────────────────────────────────────────────────┘              │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Optimized Background Tracker                              │  │
│  │  • tcpdump -i ens6 port 443 or port 5566                  │  │
│  │  • Single interface monitoring (e.g., ens6, eth0)         │  │
│  │  • GeoIP aggregation for all containers                   │  │
│  └────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  System Tuning (sysctl)                                    │  │
│  │  • net.core.somaxconn = 65535                             │  │
│  │  • net.ipv4.ip_local_port_range = 1024 65535              │  │
│  │  • net.ipv4.tcp_congestion_control = bbr                  │  │
│  │  • fs.file-max = 2097152                                  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 Key Architectural Changes

#### A. Load Balancer Layer (Nginx)
- **Purpose**: Distribute incoming connections across 40 backend containers
- **Technology**: Nginx stream module (Layer 4 TCP/UDP load balancing)
- **Configuration**: Auto-generated from script
- **Benefits**: 
  - Single entry point (ports 443, 5566)
  - Load distribution across all backends
  - Health checking (optional)
  - Connection pooling via `reuseport`

#### B. Backend Container Architecture
- **Network Mode**: Bridge (default) instead of host
- **Port Mapping**: `127.0.0.1:808X:443` and `127.0.0.1:808X:5566`
- **Container Count**: Unlimited (default 40, configurable)
- **File Descriptors**: `--ulimit nofile=65535:65535`
- **Naming**: `conduit-1` through `conduit-N`

#### C. System-Level Optimization
- **Socket Queue**: `somaxconn=65535` (up from default 128)
- **Port Range**: Expanded ephemeral ports for connections
- **TCP Algorithm**: BBR congestion control for better throughput
- **File Descriptors**: System-wide limit raised to 2M

#### D. Traffic Tracking Optimization
- **Interface**: Monitor main interface only (e.g., `ens6`, `eth0`)
- **Ports**: Filter for `port 443 or port 5566`
- **Efficiency**: No container overhead, direct host traffic capture

---

## 3. Detailed Component Specifications

### 3.1 Nginx Configuration Generator

#### Function: `generate_nginx_conf()`
**Location**: Insert after `tune_system()` function  
**Purpose**: Generate `/etc/nginx/nginx.conf` for Layer 4 load balancing

```bash
generate_nginx_conf() {
    local container_count=${1:-40}
    local nginx_conf="/etc/nginx/nginx.conf"
    
    # Backup existing config
    [ -f "$nginx_conf" ] && cp "$nginx_conf" "${nginx_conf}.backup.$(date +%s)"
    
    # Generate upstream blocks
    local tcp_upstreams=""
    local udp_upstreams=""
    for i in $(seq 1 $container_count); do
        local port=$((8080 + i))
        tcp_upstreams+="        server 127.0.0.1:${port};\n"
        udp_upstreams+="        server 127.0.0.1:${port};\n"
    done
    
    # Create configuration
    cat > "$nginx_conf" << EOF
# Psiphon Conduit High-Performance Cluster Edition v2.0
# Auto-generated configuration

user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 65535;
    use epoll;
}

stream {
    # TCP Load Balancer for port 443
    upstream conduit_tcp_443 {
        least_conn;
$(echo -e "$tcp_upstreams")
    }
    
    # UDP Load Balancer for port 5566
    upstream conduit_udp_5566 {
        hash \$remote_addr consistent;
$(echo -e "$udp_upstreams")
    }
    
    # TCP Listener with SO_REUSEPORT
    server {
        listen 443 reuseport;
        proxy_pass conduit_tcp_443;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
    
    # UDP Listener with SO_REUSEPORT
    server {
        listen 5566 udp reuseport;
        proxy_pass conduit_udp_5566;
        proxy_timeout 60s;
        proxy_responses 1;
    }
    
    # Additional TCP listener for port 5566
    server {
        listen 5566 reuseport;
        proxy_pass conduit_tcp_443;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
    }
}
EOF
    
    log_success "Nginx configuration generated for $container_count backends"
}
```

**Key Features**:
- **Dynamic upstream generation** based on container count
- **`reuseport`** flag enables multiple worker processes to bind to same port
- **`least_conn`** for TCP (distribute to least busy backend)
- **`hash $remote_addr`** for UDP (maintain session affinity)
- **Auto-backup** of existing config

---

### 3.2 System Tuning Function

#### Function: `tune_system()`
**Location**: Insert after `check_dependencies()` function  
**Purpose**: Apply kernel parameters for high-concurrency workloads

```bash
tune_system() {
    log_info "Applying system tuning for high-performance cluster..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_warn "System tuning requires root. Skipping..."
        return 1
    fi
    
    # Backup existing sysctl.conf
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.backup.$(date +%s)
    fi
    
    # Apply settings via sysctl
    sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w fs.file-max=2097152 >/dev/null 2>&1
    
    # Additional recommended settings for high concurrency
    sysctl -w net.ipv4.tcp_max_syn_backlog=8192 >/dev/null 2>&1
    sysctl -w net.core.netdev_max_backlog=5000 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_keepalive_time=300 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1
    
    # Persist to sysctl.conf
    cat >> /etc/sysctl.conf << 'EOF'

# Psiphon Conduit High-Performance Cluster Edition v2.0
# Applied: $(date)
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_congestion_control = bbr
fs.file-max = 2097152
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_tw_reuse = 1
EOF
    
    # Verify BBR is available
    if ! lsmod | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || log_warn "BBR module not available on this kernel"
    fi
    
    log_success "System tuning applied successfully"
    
    # Display verification
    echo ""
    echo -e "${CYAN}Tuning Verification:${NC}"
    echo -e "  somaxconn:        $(sysctl -n net.core.somaxconn)"
    echo -e "  port_range:       $(sysctl -n net.ipv4.ip_local_port_range)"
    echo -e "  tcp_cc:           $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo -e "  file-max:         $(sysctl -n fs.file-max)"
    echo ""
}
```

**Parameter Explanations**:
- **`somaxconn`**: Max queued connections waiting to be accepted (default: 128)
- **`ip_local_port_range`**: Available ephemeral ports for outbound connections
- **`tcp_congestion_control`**: BBR algorithm improves throughput
- **`file-max`**: System-wide file descriptor limit
- **`tcp_max_syn_backlog`**: SYN queue size for half-open connections
- **`tcp_fin_timeout`**: Reduced TIME_WAIT duration
- **`tcp_tw_reuse`**: Reuse TIME_WAIT sockets for new connections

---

### 3.3 Modified Container Deployment

#### Function: `run_conduit()` (Modified)
**Changes**:
1. Remove `--network host`
2. Add port mapping to `127.0.0.1:808X`
3. Add `--ulimit nofile=65535:65535`
4. Support unlimited container count (default 40)

```bash
run_conduit() {
    local count=${CONTAINER_COUNT:-40}
    log_info "Starting Conduit ($count container(s))..."
    
    # Ensure Nginx is configured and running
    if ! command -v nginx &>/dev/null; then
        log_info "Installing Nginx..."
        install_package nginx || { log_error "Failed to install Nginx"; exit 1; }
    fi
    
    # Generate Nginx configuration
    generate_nginx_conf "$count"
    
    # Restart Nginx with new config
    systemctl restart nginx || { log_error "Failed to start Nginx"; exit 1; }
    
    log_info "Pulling Conduit image ($CONDUIT_IMAGE)..."
    if ! docker pull "$CONDUIT_IMAGE"; then
        log_error "Failed to pull Conduit image. Check your internet connection."
        exit 1
    fi
    
    for i in $(seq 1 $count); do
        local cname="conduit-${i}"
        local vname="conduit-data-${i}"
        local port=$((8080 + i))
        
        docker rm -f "$cname" 2>/dev/null || true
        
        # Ensure volume exists with correct permissions
        docker volume create "$vname" 2>/dev/null || true
        docker run --rm -v "${vname}:/home/conduit/data" alpine \
            sh -c "chown -R 1000:1000 /home/conduit/data" 2>/dev/null || true
        
        local resource_args=""
        local cpus=$(get_container_cpus $i)
        local mem=$(get_container_memory $i)
        [ -n "$cpus" ] && resource_args+="--cpus $cpus "
        [ -n "$mem" ] && resource_args+="--memory $mem "
        
        # shellcheck disable=SC2086
        docker run -d \
            --name "$cname" \
            --restart unless-stopped \
            --log-opt max-size=15m \
            --log-opt max-file=3 \
            --ulimit nofile=65535:65535 \
            -v "${vname}:/home/conduit/data" \
            -p "127.0.0.1:${port}:443" \
            -p "127.0.0.1:${port}:5566" \
            -p "127.0.0.1:${port}:5566/udp" \
            $resource_args \
            "$CONDUIT_IMAGE" \
            start --max-clients "$MAX_CLIENTS" --bandwidth "$BANDWIDTH" --stats-file
        
        if [ $? -eq 0 ]; then
            log_success "$cname started (mapped to 127.0.0.1:${port})"
        else
            log_error "Failed to start $cname"
        fi
    done
    
    sleep 3
    if docker ps | grep -q conduit; then
        if [ "$BANDWIDTH" == "-1" ]; then
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=Unlimited, containers=$count"
        else
            log_success "Settings: max-clients=$MAX_CLIENTS, bandwidth=${BANDWIDTH}Mbps, containers=$count"
        fi
    else
        log_error "Conduit failed to start"
        docker logs conduit-1 2>&1 | tail -10
        exit 1
    fi
}
```

**Key Changes**:
- **Network**: Bridge mode with explicit port mapping
- **Ports**: Each container maps to unique `127.0.0.1:808X`
- **Ulimit**: `nofile=65535:65535` for high fd usage
- **Nginx Integration**: Auto-configure and restart Nginx

---

### 3.4 Optimized Traffic Tracker

#### Modified: `regenerate_tracker_script()` 
**Changes**: Update tcpdump command to monitor main interface only

```bash
# In the tracker script generation, replace the tcpdump line:

# OLD (line ~1824):
# tcpdump -tt -l -ni any -n -q "(tcp or udp) and not port 22"

# NEW:
# Detect main interface
MAIN_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE=$(ip route list default 2>/dev/null | awk '{print $5}')
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="eth0"

# Monitor only main interface on ports 443 and 5566
tcpdump -tt -l -i "$MAIN_IFACE" -n -q "((tcp or udp) and (port 443 or port 5566)) and not port 22"
```

**Benefits**:
- **Reduced Overhead**: No container internal traffic
- **Accurate Stats**: Only external client connections
- **Performance**: Single interface vs all interfaces

---

### 3.5 Dashboard Aggregation

#### Modified: `show_dashboard()` and `show_status()`
**Changes**: Aggregate "Connected Users" across all containers

**Current Logic** (lines 2456-2465):
```bash
# Fetches logs from each container individually
# Sums up connected counts
total_connected=$((total_connected + ${c_connected:-0}))
```

**Enhancement**:
```bash
# No changes needed - current code already aggregates!
# The existing parallel docker logs fetching is efficient.
# Just ensure the display clearly shows TOTAL users:

# In show_dashboard() around line 1169:
echo -e "  Containers: ${GREEN}${running_count}${NC}/${CONTAINER_COUNT}    "
echo -e "  ${BOLD}TOTAL Active Clients: ${GREEN}${connected}${NC}${NC} connected, ${YELLOW}${connecting}${NC} connecting"
```

**Display Update**:
```bash
# Clear indication of aggregated metrics
printf "  ${BOLD}TOTAL USERS:${NC} ${GREEN}%s${NC} connected across %d containers\n" \
    "$total_connected" "$running_count"
```

---

## 4. Breaking Changes & Migration Strategy

### 4.1 Breaking Changes

#### Network Architecture Change
- **Impact**: Containers no longer use `--network host`
- **Migration**: Existing containers must be recreated
- **Data Safety**: Docker volumes preserved

#### Port Binding Change
- **Impact**: Containers bind to `127.0.0.1:808X` instead of `0.0.0.0:443`
- **Migration**: Nginx now handles external traffic
- **Firewall**: No changes needed (still expose 443, 5566)

#### Container Count Increase
- **Impact**: Default changes from recommended 1-5 to 40
- **Migration**: Optional - users can keep lower counts
- **Resource**: Requires adequate RAM (recommend 16GB+ for 40 containers)

### 4.2 Migration Path

#### Automated Migration Script
```bash
migrate_to_v2() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     MIGRATING TO HIGH-PERFORMANCE CLUSTER EDITION v2.0            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "This will:"
    echo "  1. Stop all existing containers"
    echo "  2. Install and configure Nginx"
    echo "  3. Apply system tuning"
    echo "  4. Recreate containers with new architecture"
    echo "  5. Preserve all data volumes and backups"
    echo ""
    read -p "Continue? [y/N]: " confirm < /dev/tty || true
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    
    # Backup settings
    cp "$INSTALL_DIR/settings.conf" "$INSTALL_DIR/settings.conf.pre-v2"
    
    # Stop existing containers
    stop_conduit
    
    # Install Nginx
    install_package nginx
    
    # Apply system tuning
    tune_system
    
    # Prompt for new container count
    echo ""
    read -p "How many backend containers? [40]: " new_count < /dev/tty || true
    new_count=${new_count:-40}
    
    if ! [[ "$new_count" =~ ^[0-9]+$ ]] || [ "$new_count" -lt 1 ]; then
        new_count=40
    fi
    
    CONTAINER_COUNT=$new_count
    save_settings
    
    # Start with new architecture
    run_conduit
    
    echo ""
    log_success "Migration to v2.0 complete!"
    echo ""
}
```

### 4.3 Rollback Plan

#### Revert Script
```bash
rollback_to_v1() {
    echo "Rolling back to v1.2 architecture..."
    
    # Restore pre-v2 settings
    if [ -f "$INSTALL_DIR/settings.conf.pre-v2" ]; then
        cp "$INSTALL_DIR/settings.conf.pre-v2" "$INSTALL_DIR/settings.conf"
        source "$INSTALL_DIR/settings.conf"
    fi
    
    # Stop Nginx
    systemctl stop nginx
    systemctl disable nginx
    
    # Revert sysctl changes (optional, safe to keep)
    
    # Recreate containers with --network host
    stop_conduit
    # Use old run_conduit logic with --network host
    
    echo "Rollback complete"
}
```

---

## 5. Testing & Validation Plan

### 5.1 Unit Tests

#### Test 1: Nginx Configuration Generation
```bash
test_nginx_config() {
    generate_nginx_conf 40
    nginx -t -c /etc/nginx/nginx.conf
    [ $? -eq 0 ] && echo "✓ Nginx config valid" || echo "✗ Nginx config invalid"
}
```

#### Test 2: System Tuning Verification
```bash
test_system_tuning() {
    tune_system
    local somaxconn=$(sysctl -n net.core.somaxconn)
    [ "$somaxconn" -eq 65535 ] && echo "✓ somaxconn tuned" || echo "✗ somaxconn failed"
}
```

#### Test 3: Container Port Mapping
```bash
test_port_mapping() {
    run_conduit
    sleep 5
    for i in $(seq 1 $CONTAINER_COUNT); do
        local port=$((8080 + i))
        nc -zv 127.0.0.1 $port 2>&1 | grep -q succeeded && echo "✓ Port $port open" || echo "✗ Port $port closed"
    done
}
```

### 5.2 Load Testing

#### Load Test Scenario
```bash
# Use tool like 'wrk' or 'hey' to test Nginx load distribution
hey -z 60s -c 100 https://your-server:443

# Monitor backend distribution
watch -n1 'docker stats --no-stream | grep conduit'

# Verify Nginx load balancing
tail -f /var/log/nginx/error.log
```

### 5.3 Performance Benchmarks

#### Metrics to Track
1. **Max Concurrent Connections**: Target 40,000
2. **Connection Distribution**: Balanced across backends
3. **Response Time**: <100ms p50, <500ms p99
4. **CPU Usage**: <80% system-wide
5. **Memory Usage**: <16GB for 40 containers
6. **File Descriptors**: Monitor with `lsof | wc -l`

---

## 6. Documentation Updates

### 6.1 User-Facing Changes

#### README.md Updates
```markdown
## High-Performance Cluster Edition v2.0

### What's New
- **40,000 Concurrent Users**: Scale to enterprise-grade capacity
- **Nginx Load Balancer**: Automatic traffic distribution
- **System Tuning**: Kernel optimizations for high concurrency
- **40 Backend Containers**: Default configuration (adjustable)

### Requirements
- **RAM**: 16GB+ recommended for 40 containers
- **CPU**: 8+ cores recommended
- **Network**: 1Gbps+ connection
- **OS**: Linux with kernel 4.9+ (for BBR support)

### Installation
\`\`\`bash
curl -sL https://raw.githubusercontent.com/tondhoosh/CONDUIT-CLUSTER-MANAGER/main/conduit-v2-complete.sh | sudo bash
\`\`\`

### Migration from v1.x
\`\`\`bash
sudo conduit migrate-to-v2
\`\`\`
```

### 6.2 CLI Help Updates

```bash
# Add new commands
conduit tune          # Apply system tuning
conduit nginx         # Manage Nginx configuration
conduit migrate-to-v2 # Migrate from v1.x
```

---

## 7. Implementation Checklist

### Phase 1: Core Infrastructure
- [ ] Implement `tune_system()` function
- [ ] Implement `generate_nginx_conf()` function
- [ ] Install Nginx during setup if not present
- [ ] Test Nginx configuration generation

### Phase 2: Container Architecture
- [ ] Modify `run_conduit()` to use bridge networking
- [ ] Add port mapping logic (127.0.0.1:808X)
- [ ] Add `--ulimit nofile=65535:65535`
- [ ] Remove MAX_CONTAINERS limit (keep validation)
- [ ] Update container count default to 40

### Phase 3: Tracking Optimization
- [ ] Modify tracker script to detect main interface
- [ ] Update tcpdump filter to ports 443, 5566
- [ ] Test tracker with new architecture
- [ ] Verify GeoIP still works correctly

### Phase 4: Dashboard Updates
- [ ] Update dashboard to show "TOTAL" users
- [ ] Ensure aggregation logic is clear
- [ ] Add container distribution visualization
- [ ] Test with 40 containers

### Phase 5: Migration & Testing
- [ ] Implement `migrate_to_v2()` function
- [ ] Implement `rollback_to_v1()` function
- [ ] Create test suite
- [ ] Perform load testing
- [ ] Document performance results

### Phase 6: Documentation
- [ ] Update README.md
- [ ] Create migration guide
- [ ] Update CLI help text
- [ ] Add troubleshooting section

---

## 8. Performance Expectations

### 8.1 Capacity Planning

#### Baseline (v1.2)
- **Max Users**: ~2,000 (5 containers × 400 clients)
- **Architecture**: Direct host networking
- **Bottleneck**: Container count limit

#### Target (v2.0)
- **Max Users**: 40,000 (40 containers × 1,000 clients)
- **Architecture**: Nginx load balancer
- **Bottleneck**: System resources (RAM, CPU, network)

### 8.2 Resource Requirements

#### Per Container (avg)
- **RAM**: ~128-256MB per container
- **CPU**: ~0.25 cores per container at 1k clients
- **FD**: ~5,000 file descriptors per container

#### Total System (40 containers)
- **RAM**: 8-16GB (includes OS overhead)
- **CPU**: 8-16 cores (depends on traffic)
- **FD**: ~200,000 system-wide
- **Network**: 1Gbps+ recommended

---

## 9. Troubleshooting Guide

### Issue: Nginx fails to start
**Symptom**: `nginx: [emerg] bind() to 0.0.0.0:443 failed`
**Solution**: Check if another process is using port 443
```bash
sudo lsof -i :443
sudo systemctl stop apache2  # if Apache is running
```

### Issue: Containers can't reach internet
**Symptom**: No client connections, tracker shows no traffic
**Solution**: Check Docker network and iptables
```bash
docker network inspect bridge
sudo iptables -L -n -v
```

### Issue: System runs out of file descriptors
**Symptom**: `too many open files` errors
**Solution**: Verify ulimit and sysctl settings
```bash
ulimit -n
sysctl fs.file-max
cat /proc/sys/fs/file-nr
```

### Issue: Uneven load distribution
**Symptom**: Some containers have many clients, others have few
**Solution**: Check Nginx upstream configuration
```bash
nginx -T | grep -A10 "upstream conduit"
# Verify all backends are listed
docker ps | grep conduit  # Ensure all running
```

---

## 10. Security Considerations

### 10.1 Network Isolation
- **Backend Containers**: Bound to 127.0.0.1 only (not accessible externally)
- **Nginx Frontend**: Only exposed ports 443, 5566
- **Firewall**: Same rules as v1.x

### 10.2 Resource Limits
- **Per-Container Limits**: Prevent resource exhaustion
- **System Limits**: Prevent DoS via file descriptor exhaustion
- **Connection Limits**: Nginx can enforce per-IP limits

### 10.3 Recommended Firewall Rules
```bash
# Allow only required ports
ufw allow 22/tcp      # SSH
ufw allow 443/tcp     # Conduit TCP
ufw allow 5566/tcp    # Conduit TCP
ufw allow 5566/udp    # Conduit UDP
ufw enable
```

---

## Conclusion

The High-Performance Cluster Edition v2.0 represents a significant architectural upgrade:

### Key Benefits
1. **20x Capacity Increase**: 2,000 → 40,000 users
2. **Professional Load Balancing**: Nginx Layer 4 distribution
3. **System Optimization**: Kernel tuning for high concurrency
4. **Better Resource Management**: Proper container isolation
5. **Improved Monitoring**: Efficient single-interface tracking

### Implementation Priority
1. **Critical**: System tuning, Nginx setup, container networking
2. **Important**: Tracker optimization, dashboard aggregation
3. **Nice-to-have**: Migration scripts, advanced monitoring

### Next Steps
1. Review this architecture document
2. Approve the design approach
3. Begin Phase 1 implementation
4. Test on staging environment
5. Deploy to production with monitoring

---

**Document Version**: 1.0  
**Date**: 2026-02-01  
**Author**: Architecture Team  
**Status**: Ready for Implementation
