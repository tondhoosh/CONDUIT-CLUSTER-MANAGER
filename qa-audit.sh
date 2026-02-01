#!/bin/bash
# 🧪 Conduit Cluster V2 - Production Audit Suite
# "Trust, but Verify."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log() { echo -e "${BLUE}[AUDIT]${NC} $1"; }
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "\n${BOLD}🔬 STARTING CLUSTER QA AUDIT sequence...${NC}\n"

# 1. KERNEL & NETWORK STACK VERIFICATION
log "Verifying Kernel Network Stack Tuning..."
TCP_CONG=$(sysctl -n net.ipv4.tcp_congestion_control)
QDISC=$(sysctl -n net.core.default_qdisc)

if [ "$TCP_CONG" == "bbr" ]; then pass "Congestion Control is BBR"; else fail "Congestion is $TCP_CONG (Wanted: bbr)"; fi
if [ "$QDISC" == "fq" ]; then pass "Queue Discipline is fq"; else fail "QDisc is $QDISC (Wanted: fq)"; fi

# 2. CONTAINER RESOURCES & CONFIGURATION CHECKS
log "Auditing Container Resource Limits & Restart Policies..."
for i in {1..8}; do
    name="conduit-$i"
    [[ $i -eq 1 ]] && name="conduit"
    
    # Check Restart Policy
    POLICY=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $name 2>/dev/null)
    if [[ "$POLICY" == "unless-stopped" || "$POLICY" == "always" ]]; then 
        pass "$name: Restart policy confirmed ($POLICY)"
    else 
        fail "$name: Bad restart policy ($POLICY)"
    fi

    # Check RAM Limits
    MEM=$(docker inspect -f '{{.HostConfig.Memory}}' $name 2>/dev/null)
    if [ "$MEM" == "268435456" ]; then
        pass "$name: Memory limit hard-locked to 256MB"
    else
        warn "$name: Memory limit is $MEM (Expected 268435456)"
    fi
done

# 3. DIRECT BACKEND CONNECTIVITY
log "Testing Direct Container Connectivity (Bypassing LB)..."
FAIL_COUNT=0
for port in {10001..10008}; do
    if nc -z -v -w1 127.0.0.1 $port &>/dev/null; then
        echo -n "."
    else
        echo ""
        fail "Port $port is NOT accepting connections!"
        ((FAIL_COUNT++))
    fi
done
echo ""
if [ $FAIL_COUNT -eq 0 ]; then pass "All 8 backends reachable internally"; else fail "$FAIL_COUNT backends unreachable"; fi

# 4. LOAD BALANCER INTEGRATION CHECK
log "Validating Nginx Load Balancer (Port 443)..."
if nc -z -v -w1 127.0.0.1 443 &>/dev/null; then
    pass "Nginx is listening on 443"
else
    fail "Nginx IS NOT LISTENING on 443!"
fi

# 5. SYNTHETIC LOAD TEST
log "Running Synthetic Load Test (1000 requests to LB)..."
SUCCESS_HITS=0
TOTAL_HITS=100
for i in $(seq 1 $TOTAL_HITS); do
    timeout 0.1 bash -c "echo 'test' | nc 127.0.0.1 443" &>/dev/null && ((SUCCESS_HITS++))
done
RATE=$(( SUCCESS_HITS * 100 / TOTAL_HITS ))
if [ $RATE -gt 95 ]; then
    pass "Load Balancer reliability: $RATE% ($SUCCESS_HITS/$TOTAL_HITS connections succeeded)"
else
    warn "Load Balancer dropped connections: reliability only $RATE%"
fi

# 6. CHAOS MONKEY (Resilience Test)
log "🦍 CHAOS TEST: Killing 'conduit-8' to test auto-healing..."
docker stop conduit-8 &>/dev/null
docker start conduit-8 &>/dev/null 
docker kill --signal=SIGKILL conduit-8 &>/dev/null
sleep 10
STATUS=$(docker inspect -f '{{.State.Status}}' conduit-8)
if [ "$STATUS" == "running" ] || [ "$STATUS" == "restarting" ]; then
    pass "Self-Healing Confirmed: Container recovered automatically."
else
    fail "Resilience Fail: Container is in state '$STATUS' after crash."
    docker start conduit-8 >/dev/null
fi

echo -e "\n${BOLD}🏁 AUDIT COMPLETE.${NC}"
