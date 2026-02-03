#!/bin/bash
# Conduit V2 Architecture - Institutional Self-Testing Suite
# Validates implementation against TEST-PLAN.md (v2.5-iran-ipv6)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
BOLD='\033[1m'
AUDIT_MODE=false

# Simple argument parsing
if [ "$1" == "--audit" ]; then
    AUDIT_MODE=true
fi

pass() { 
    echo -e "${GREEN}[PASS]${NC} $1"
}

fail() { 
    echo -e "${RED}[FAIL]${NC} $1"
    if [ "$AUDIT_MODE" = true ]; then echo "Audit Failed: Intervention Required"; exit 1; fi
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

info() { 
    echo -e "${BOLD}[INFO]${NC} $1"
}

if [ "$AUDIT_MODE" = true ]; then
    echo "========================================================="
    echo "   📋 CONDUIT CLUSTER V2.5 - COMPLIANCE AUDIT"
    echo "   Date: $(date)"
    echo "   Host: $(hostname)"
    echo "========================================================="
else
    echo "========================================================="
    echo "   🧬 CONDUIT ARCHITECTURE V2.5 - SELF-TEST PROTOCOL    "
    echo "========================================================="
fi

# Load Settings
INSTALL_DIR="/opt/conduit"
[ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
CONTAINER_COUNT="${CONTAINER_COUNT:-8}"

# TC-000: PRE-FLIGHT NETWORK CHECKS (INTERNAL/EXTERNAL)
info "TC-000: Verifying Network Configuration..."

# 1. DNS Check
if grep -qE "8.8.8.8|1.1.1.1" /etc/resolv.conf; then
    pass "DNS Configured: Secure Resolver Found"
else
    warn "DNS Verification: Using Standard/ISP Resolver (Check /etc/resolv.conf)"
fi

# 2. External Connectivity
# Baseline Check (Google) - Verifies global routing
if curl -s -I --connect-timeout 5 https://www.google.com | grep -qE "200|301|302"; then
    pass "Connectivity Baseline: Google Reachable"
else
    warn "Connectivity Baseline: Google Unreachable (High Latency or Blocking)"
fi

# Critical Check (Raw GitHub) - Verifies update capability
if curl -s -I --connect-timeout 5 https://raw.githubusercontent.com/tondhoosh/CONDUIT-CLUSTER-MANAGER/main/conduit.sh | grep -q "200 OK"; then
    pass "Update Capability: Raw GitHub Reachable"
else
    # Only fail if we can't get updates. 
    # Note: If this fails but Conduit works, it's just an update blocker.
    warn "Update Capability: Raw GitHub Unreachable (Updates may fail)"
fi

# 3. Internal Bridge Check (Docker)
if ip addr show docker0 > /dev/null 2>&1; then
    pass "Internal Networking: Docker Bridge (docker0) Active"
else
    fail "Internal Networking: Docker Bridge Missing or Down"
fi


# TC-001: KERNEL OPTIMIZATION (BBR)
info "TC-001: Verifying Network Stack Optimization..."
tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$tcp_cc" == "bbr" ]; then
    pass "Kernel Tuned: BBR Active"
else
    warn "Kernel Mismatch: Found CC=$tcp_cc (Expected: bbr)"
fi

# TC-002: CLUSTER HEALTH & ISOLATION
info "TC-002: Verifying Cluster Health..."
container_count=$(docker ps --format '{{.Names}}' | grep -Ex "conduit(-[0-9]+)?" | wc -l)
if [ "$container_count" -ge "$CONTAINER_COUNT" ]; then
    pass "Cluster Capacity: $container_count/$CONTAINER_COUNT containers active"
else
    fail "Cluster Degraded: Only $container_count/$CONTAINER_COUNT containers active"
fi

# Check Isolation (Localhost Binding)
exposed_ports=$(netstat -tulpn | grep docker-pr | grep -v "127.0.0.1" | grep -v "::1" | wc -l)
if [ "$exposed_ports" -eq 0 ]; then
    pass "Isolation Verified: No containers exposed to public WAN"
else
    warn "Security Risk: $exposed_ports container ports exposed publicly!"
fi

# TC-003: LOAD BALANCER & IPv6 REACHABILITY
info "TC-003: Verifying Dual-Stack Load Balancer..."
listeners=$(netstat -tulpn | grep nginx)

check_listener() {
    local port=$1
    if echo "$listeners" | grep -q ":$port "; then
        pass "Nginx Listening on IPv4 Port $port"
    else
        fail "Missing IPv4 Listener on Port $port"
    fi
    
    if echo "$listeners" | grep -q ":::$port "; then
        pass "Nginx Listening on IPv6 Port $port"
    else
        warn "Missing IPv6 Listener on Port $port"
    fi
}

check_listener 443
check_listener 80
check_listener 53
check_listener 2053
check_listener 5566

# TC-004: PERSISTENCE CONFIGURATION
info "TC-004: Verifying Data Persistence..."
first_container=$(docker ps --format '{{.Names}}' | grep -Ex "conduit(-[0-9]+)?" | head -1)
if [ -n "$first_container" ]; then
    mount=$(docker inspect "$first_container" | grep -A 5 "Mounts" | grep "Source")
    if [[ "$mount" == *"/var/lib/docker/volumes/"* ]] || [[ "$mount" == *"/data"* ]]; then
        pass "Persistence Managed: Volume/Host Path confirmed"
    else
        fail "Persistence Risk: No valid mount found for $first_container"
        echo "$mount"
    fi
else
    warn "Skipping Persistence Check (No containers)"
fi

# TC-005: FUNCTIONAL STEALTH (PROBE RESISTANCE)
info "TC-005: Verifying Stealth Behavior (Probe Resistance)..."
response_v4=$(curl -I -k https://127.0.0.1 2>&1)
if [[ "$response_v4" == *"SSL_ERROR_SYSCALL"* ]] || [[ "$response_v4" == *"Connection reset"* ]] || [[ "$response_v4" == *"Empty reply"* ]]; then
    pass "IPv4 Stealth Confirmed: Connection Reset"
else
    warn "IPv4 Stealth Anomaly: Server responded to probe: $(echo "$response_v4" | head -1)"
fi

response_v6=$(curl -I -k -6 https://[::1] 2>&1)
if [[ "$response_v6" == *"SSL_ERROR_SYSCALL"* ]] || [[ "$response_v6" == *"Connection reset"* ]] || [[ "$response_v6" == *"Empty reply"* ]]; then
    pass "IPv6 Stealth Confirmed: Connection Reset"
else
    warn "IPv6 Stealth Anomaly: Server responded to probe: $(echo "$response_v6" | head -1)"
fi

# TC-006: UPSTREAM HEALTH
info "TC-006: Verifying Upstream Handshakes..."
connected_count=0
containers=$(docker ps --format '{{.Names}}' | grep -Ex "conduit(-[0-9]+)?")
for name in $containers; do
    if docker logs --tail 50 $name 2>&1 | grep -q "Connected to Psiphon network"; then
        ((connected_count++))
    fi
done

total=$(echo "$containers" | wc -w)
if [ "$connected_count" -ge "$total" ] && [ "$total" -gt 0 ]; then
    pass "Functional: All $total nodes connected to Psiphon Network"
else
    warn "Functional: Only $connected_count/$total nodes connected"
fi

# TC-007: RESOURCE SAFETY & STABILITY
info "TC-007: Verifying Resource Limits..."
disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')

# Disk Check (< 80% is healthy)
if [ "$disk_usage" -lt 80 ]; then
    pass "Disk Usage: $disk_usage% (Healthy)"
else
    warn "Disk Usage: $disk_usage% (High Usage!)"
fi

# Load Check (Simple check: warn if load > 5 on a typical VPS)
if (( $(echo "$load_avg < 5.0" | bc -l) )); then
    pass "System Load: $load_avg (Stable)"
else
    warn "System Load: $load_avg (High Load!)"
fi

echo "========================================================="
echo "   ✅ SELF-TEST COMPLETE"
echo "========================================================="
exit 0
