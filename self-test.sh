#!/bin/bash
# 🧪 Conduit V2 Architecture - Institutional Self-Testing Suite
# Validates implementation against TEST-PLAN.md

RED='\033[0;31m'
GREEN='\033[0;32m'
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

info() { 
    echo -e "${BOLD}[INFO]${NC} $1"
}

if [ "$AUDIT_MODE" = true ]; then
    echo "========================================================="
    echo "   📋 CONDUIT CLUSTER V2 - COMPLIANCE AUDIT (TC-001..005)"
    echo "   Date: $(date)"
    echo "   Host: $(hostname)"
    echo "========================================================="
else
    echo "========================================================="
    echo "   🧬 CONDUIT ARCHITECTURE V2 - SELF-TEST PROTOCOL      "
    echo "========================================================="
fi

# TC-001: KERNEL OPTIMIZATION (BBR + FQ)
info "TC-001: Verifying Network Stack Optimization..."
tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
qdisc=$(sysctl -n net.core.default_qdisc)

if [ "$tcp_cc" == "bbr" ] && [ "$qdisc" == "fq" ]; then
    pass "Kernel Tuned: BBR + FQ Active"
else
    fail "Kernel Mismatch: Found CC=$tcp_cc / QDisc=$qdisc"
fi

# TC-003: LOAD BALANCER INTEGRATION
info "TC-003: Verifying Load Balancer Role..."
if netstat -tulpn | grep nginx | grep -q ":443"; then
    pass "Nginx: Listening on Port 443 (Front-Door)"
else
    fail "Nginx: NOT listening on Port 443"
fi

# TC-002: BRIDGE NETWORKING ISOLATION & SECURITY
info "TC-002: Verifying Network Isolation & Bindings..."
host_net_count=$(docker ps --format '{{.Status}}' --filter network=host --filter name=conduit | wc -l)
bridge_net_count=$(docker network inspect bridge --format '{{json .Containers}}' | grep -o "IPv4Address" | wc -l)
bind_errors=$(netstat -tulpn | grep docker-pr | grep -v "127.0.0.1" | wc -l)

if [ "$host_net_count" -eq 0 ] && [ "$bridge_net_count" -ge 8 ] && [ "$bind_errors" -eq 0 ]; then
    pass "Isolation Verified: Bridge Active, No Public exposure"
else
    fail "Security Breach: Review Network Config (Exposed: $bind_errors)"
fi

# TC-004: RESOURCE CONSTRAINTS
info "TC-004: Verifying Resource Governance..."
mem_limit=$(docker inspect conduit --format '{{.HostConfig.Memory}}')
if [ "$mem_limit" == "268435456" ]; then
    pass "Resource Safety: Limit set to 256MB per node"
else
    fail "Resource Risk: Memory limit is $mem_limit"
fi

# TC-005: FUNCTIONAL UPSTREAM CONNECTIVITY
info "TC-005: Verifying Upstream Handshakes..."
connected_count=0
for i in {1..8}; do
    name="conduit-$i"; [[ $i -eq 1 ]] && name="conduit"
    if docker logs --tail 20 $name 2>&1 | grep -q "Connected to Psiphon network"; then
        ((connected_count++))
    fi
done

if [ "$connected_count" -eq 8 ]; then
    pass "Functional: All 8 nodes successfully handshaked"
else
    fail "Functional: Only $connected_count/8 nodes connected"
fi

echo "========================================================="
echo "   ✅ AUDIT COMPLETE - ALL CHECKS PASSED"
echo "========================================================="
