#!/bin/bash
#
# Conduit Cluster Manager - Simple Operations Tool
# For managing your 8-container Conduit cluster
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Display cluster status
cluster_status() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              CONDUIT CLUSTER STATUS                               ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # System info
    echo -e "${BOLD}System Resources:${NC}"
    free -h | grep Mem | awk '{printf "  RAM: %s / %s used (%.1f%%)\n", $3, $2, ($3/$2)*100}'
    echo -e "  CPU Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo ""
    
    # Container status
    echo -e "${BOLD}Containers:${NC}"
    local running=$(docker ps -q --filter "name=conduit" | wc -l)
    echo -e "  Running: ${GREEN}$running${NC} / 8"
    echo ""
    
    # Connection stats
    echo -e "${BOLD}Active Connections:${NC}"
    local total_clients=0
    for i in {1..8}; do
        name="conduit-$i"
        [[ $i -eq 1 ]] && name="conduit"
        
        if docker ps --filter "name=^${name}$" --format "{{.Names}}" | grep -q "^${name}$"; then
            clients=$(docker exec $name cat /data/stats.json 2>/dev/null | grep -o '"connectedClients":[0-9]*' | cut -d: -f2)
            clients=${clients:-0}
            total_clients=$((total_clients + clients))
            
            if [ "$clients" -gt 0 ]; then
                echo -e "  ${GREEN}●${NC} $name: $clients clients"
            else
                echo -e "  ${YELLOW}○${NC} $name: $clients clients"
            fi
        else
            echo -e "  ${RED}✗${NC} $name: stopped"
        fi
    done
    
    echo ""
    echo -e "${BOLD}Total Active Clients: ${GREEN}$total_clients${NC}${NC}"
    
    # Nginx status
    echo ""
    echo -e "${BOLD}Load Balancer:${NC}"
    if systemctl is-active nginx &>/dev/null; then
        local connections=$(netstat -an | grep :443 | grep ESTABLISHED | wc -l)
        echo -e "  Nginx: ${GREEN}Active${NC} ($connections connections on port 443)"
    else
        echo -e "  Nginx: ${RED}Stopped${NC}"
    fi
    
    # Network tuning
    echo ""
    echo -e "${BOLD}Network Optimization:${NC}"
    local bbr=$(sysctl -n net.ipv4.tcp_congestion_control)
    local qdisc=$(sysctl -n net.core.default_qdisc)
    echo -e "  Congestion Control: ${GREEN}$bbr${NC}"
    echo -e "  Queue Discipline: ${GREEN}$qdisc${NC}"
    echo ""
}

# Live monitoring (refreshes every 5 seconds)
cluster_monitor() {
    echo -e "${YELLOW}Starting live monitor... (Press Ctrl+C to exit)${NC}"
    sleep 2
    
    while true; do
        clear
        cluster_status
        echo -e "${BLUE}[Auto-refresh in 5s]${NC}"
        sleep 5
    done
}

# Show detailed container info
container_details() {
    echo -e "${CYAN}Container Resource Usage:${NC}"
    echo ""
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
        $(docker ps -q --filter "name=conduit")
}

# Restart a specific container or all
restart_containers() {
    if [ -z "$1" ]; then
        echo -e "${YELLOW}Restarting all containers...${NC}"
        docker restart $(docker ps -q --filter "name=conduit")
        echo -e "${GREEN}✓ All containers restarted${NC}"
    else
        echo -e "${YELLOW}Restarting $1...${NC}"
        docker restart "$1"
        echo -e "${GREEN}✓ $1 restarted${NC}"
    fi
}

# Check container logs
view_logs() {
    local container=${1:-conduit}
    local lines=${2:-50}
    
    echo -e "${CYAN}Last $lines lines from $container:${NC}"
    docker logs --tail $lines "$container"
}

# Get claiming information
show_claim_info() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              NODE CLAIMING INFORMATION                            ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    echo -e "${BOLD}Server IP:${NC} $(curl -s ifconfig.me)"
    echo -e "${BOLD}Port:${NC} 443"
    echo ""
    
    echo -e "${BOLD}Mnemonic:${NC}"
    docker exec conduit cat /data/conduit_key.json 2>/dev/null | grep mnemonic | cut -d'"' -f4
    echo ""
    
    echo -e "${YELLOW}Use this mnemonic to claim your node in the Psiphon dashboard${NC}"
}

# Scale cluster (add or remove containers)
scale_cluster() {
    local target_count=$1
    
    if [ -z "$target_count" ]; then
        echo -e "${RED}Error: Please specify target container count${NC}"
        echo "Usage: $0 scale <number>"
        return 1
    fi
    
    if [ "$target_count" -lt 1 ] || [ "$target_count" -gt 16 ]; then
        echo -e "${RED}Error: Container count must be between 1 and 16${NC}"
        return 1
    fi
    
    local current=$(docker ps -q --filter "name=conduit" | wc -l)
    echo -e "${YELLOW}Current: $current containers → Target: $target_count containers${NC}"
    echo ""
    
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        return 0
    fi
    
    if [ "$target_count" -gt "$current" ]; then
        # Scale up
        echo -e "${GREEN}Scaling up...${NC}"
        for i in $(seq $((current + 1)) $target_count); do
            name="conduit-$i"
            port=$((10000 + i))
            vol="conduit-data-$i"
            
            docker volume create "$vol"
            docker run -d --name "$name" --restart unless-stopped \
                -p 127.0.0.1:$port:8080 \
                --memory=256m --cpus=0.1 \
                -v "$vol:/data" \
                ghcr.io/psiphon-inc/conduit/cli:latest \
                start -d /data --max-clients 1000 --bandwidth -1
            
            echo "  ✓ Started $name on port $port"
        done
        
        echo ""
        echo -e "${YELLOW}⚠ Remember to update Nginx config to include new backends!${NC}"
        
    else
        # Scale down
        echo -e "${YELLOW}Scaling down...${NC}"
        for i in $(seq $((target_count + 1)) $current); do
            name="conduit-$i"
            docker stop "$name"
            docker rm "$name"
            echo "  ✓ Stopped and removed $name"
        done
    fi
    
    echo ""
    echo -e "${GREEN}✓ Scaling complete${NC}"
}

# Health check
health_check() {
    echo -e "${CYAN}Running Health Check...${NC}"
    echo ""
    
    local failed=0
    
    # Check Docker
    if docker info &>/dev/null; then
        echo -e "${GREEN}✓${NC} Docker is running"
    else
        echo -e "${RED}✗${NC} Docker is not responding"
        failed=$((failed + 1))
    fi
    
    # Check Nginx
    if systemctl is-active nginx &>/dev/null; then
        echo -e "${GREEN}✓${NC} Nginx is running"
        
        if nginx -t &>/dev/null; then
            echo -e "${GREEN}✓${NC} Nginx configuration is valid"
        else
            echo -e "${RED}✗${NC} Nginx configuration has errors"
            failed=$((failed + 1))
        fi
    else
        echo -e "${RED}✗${NC} Nginx is not running"
        failed=$((failed + 1))
    fi
    
    # Check containers
    local expected=8
    local running=$(docker ps -q --filter "name=conduit" | wc -l)
    
    if [ "$running" -eq "$expected" ]; then
        echo -e "${GREEN}✓${NC} All $expected containers are running"
    else
        echo -e "${YELLOW}⚠${NC} Only $running/$expected containers are running"
    fi
    
    # Check port bindings
    local ports_ok=0
    for port in {10001..10008}; do
        if netstat -tuln | grep -q ":$port "; then
            ports_ok=$((ports_ok + 1))
        fi
    done
    
    if [ "$ports_ok" -eq 8 ]; then
        echo -e "${GREEN}✓${NC} All container ports are bound (10001-10008)"
    else
        echo -e "${YELLOW}⚠${NC} Only $ports_ok/8 container ports are bound"
    fi
    
    # Check Nginx listening
    if netstat -tuln | grep -q ":443 "; then
        echo -e "${GREEN}✓${NC} Nginx is listening on port 443"
    else
        echo -e "${RED}✗${NC} Nginx is not listening on port 443"
        failed=$((failed + 1))
    fi
    
    # Check BBR
    local bbr=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$bbr" = "bbr" ]; then
        echo -e "${GREEN}✓${NC} BBR congestion control is active"
    else
        echo -e "${YELLOW}⚠${NC} BBR is not active (using $bbr)"
    fi
    
    echo ""
    if [ "$failed" -eq 0 ]; then
        echo -e "${GREEN}Health check passed!${NC}"
        return 0
    else
        echo -e "${RED}Health check failed ($failed issues)${NC}"
        return 1
    fi
}

# Show menu
show_menu() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           CONDUIT CLUSTER MANAGEMENT TOOL                         ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  1. 📊 Show cluster status"
    echo "  2. 📺 Live monitoring (auto-refresh)"
    echo "  3. 💻 Container resource usage"
    echo "  4. 🔄 Restart containers"
    echo "  5. 📋 View container logs"
    echo "  6. 🔑 Show claiming information"
    echo "  7. ⚖️  Scale cluster"
    echo "  8. 🩺 Run health check"
    echo "  0. 🚪 Exit"
    echo ""
}

# Main
case "${1:-menu}" in
    status)
        cluster_status
        ;;
    monitor)
        cluster_monitor
        ;;
    details)
        container_details
        ;;
    restart)
        restart_containers "$2"
        ;;
    logs)
        view_logs "$2" "$3"
        ;;
    claim)
        show_claim_info
        ;;
    scale)
        scale_cluster "$2"
        ;;
    health)
        health_check
        ;;
    menu|*)
        while true; do
            show_menu
            read -p "Select option: " choice
            
            case $choice in
                1) cluster_status; read -p "Press Enter to continue..." ;;
                2) cluster_monitor ;;
                3) container_details; read -p "Press Enter to continue..." ;;
                4) 
                    read -p "Container name (or press Enter for all): " name
                    restart_containers "$name"
                    read -p "Press Enter to continue..."
                    ;;
                5)
                    read -p "Container name [conduit]: " name
                    name=${name:-conduit}
                    read -p "Number of lines [50]: " lines
                    lines=${lines:-50}
                    view_logs "$name" "$lines"
                    read -p "Press Enter to continue..."
                    ;;
                6) show_claim_info; read -p "Press Enter to continue..." ;;
                7)
                    read -p "Target container count [8]: " count
                    count=${count:-8}
                    scale_cluster "$count"
                    read -p "Press Enter to continue..."
                    ;;
                8) health_check; read -p "Press Enter to continue..." ;;
                0) exit 0 ;;
                *) echo "Invalid option" ;;
            esac
        done
        ;;
esac
