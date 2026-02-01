#!/bin/bash
# 🧪 Conduit V2 Architecture - Self-Testing Suite
# Validates the implementation against the "Conduit Cluster V2 Iran-Optimized" specification.

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
BOLD='\033[1m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${BOLD}[INFO]${NC} $1"; }

echo "========================================================="
echo "   🧬 CONDUIT ARCHITECTURE V2 - SELF-TEST PROTOCOL      "
echo "========================================================="

# SPEC 1: KERNEL OPTIMIZATION (BBR + FQ)
# Requirement: Throughput optimization for high-latency networks
info "1. Verifying Network Stack Optimization (Iran-Spec)..."
tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
qdisc=$(sysctl -n net.core.default_qdisc)

if [ "$tcp_cc" == "bbr" ] && [ "$qdisc" == "fq" ]; then
    pass "Kernel Tuned: BBR + FQ Active"
else
    fail "Kernel Mismatch: Found CC=$tcp_cc / QDisc=$qdisc"
fi

# SPEC 2: LOAD BALANCER INTEGRATION
# Requirement: Nginx must act as Layer 4 entry point on Port 443
info "2. Verifying Load Balancer Architecture..."
if netstat -tulpn | grep nginx | grep -q ":443"; then
    pass "Nginx: Listening on Port 443 (Front-Door)"
else
    fail "Nginx: NOT listening on Port 443"
fi

# SPEC 3: BRIDGE NETWORKING ISOLATION
# Requirement: Containers must NOT use 'host' network; must be on 'bridge'
info "3. Verifying Container Network Isolation..."
host_net_count=$(docker ps --format '{{.Status}}' --filter network=host --filter name=conduit | wc -l)
bridge_net_count=$(docker network inspect bridge --format '{{json .Containers}}' | grep -o "IPv4Address" | wc -l)

if [ "$host_net_count" -eq 0 ] && [ "$bridge_net_count" -ge 8 ]; then
    pass "Isolation Verified: $bridge_net_count containers on Bridge, 0 on Host"
else
    fail "Network Breach: Containers not strictly bridged (Bridge: $bridge_net_count, Host: $host_net_count)"
fi

# SPEC 4: RESOURCE CONSTRAINTS
# Requirement: Per-container limits to prevent OOM
info "4. Verifying Resource Constraints..."
mem_limit=$(docker inspect conduit --format '{{.HostConfig.Memory}}')
if [ "$mem_limit" == "268435456" ]; then
    pass "Memory Safety: Limit set to 256MB per node"
else
    fail "Resource Risk: Memory limit is $mem_limit"
fi

# SPEC 5: FUNCTIONAL UPSTREAM CONNECTIVITY
# Requirement: End-to-end connectivity to Psiphon Network
info "5. Verifying Upstream Connectivity..."
if docker logs --tail 20 conduit | grep -q "Connected to Psiphon network"; then
    pass "Functional: Container successfully handshaked with Psiphon Core"
else
    fail "Functional: No handshake detected in logs"
fi

echo "========================================================="
echo "   🏁 ARCHITECTURE COMPLIANCE CHECK COMPLETE            "
echo "========================================================="
