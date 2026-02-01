#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════
# Conduit v2.0 UI Module - Critical & High Priority Features
#═══════════════════════════════════════════════════════════════════════════
# This module adds interactive UI features to conduit-v2.0.sh
# 
# FEATURES INCLUDED:
# - Interactive Menu Loop (Critical)
# - Settings Management (High)
# - Container Management (High)  
# - Live Stats & Peers (High)
#
# TO USE: Source this file at the end of conduit-v2.0.sh
# OR: Merge functions into main script
#═══════════════════════════════════════════════════════════════════════════

#═══════════════════════════════════════════════════════════════════════════
# Settings Management (High Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Container Management (High Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Live Stats & Peers (High Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Interactive Menu Loop (Critical Priority)
#═══════════════════════════════════════════════════════════════════════════

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

echo "Conduit v2.0 UI Module loaded successfully."
echo "Critical & High Priority features available."
