#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════
# Conduit v2.0 Tools Module - QR Codes, Backup/Restore, Update
#═══════════════════════════════════════════════════════════════════════════
# Utility features for node management and updates
#
# FEATURES:
# - QR code generation for all containers
# - Node identity backup/restore
# - Update mechanism
# - Info & help pages
#═══════════════════════════════════════════════════════════════════════════

#═══════════════════════════════════════════════════════════════════════════
# QR Code Generation (Medium Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Backup & Restore (Medium Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Update Mechanism (Low Priority)
#═══════════════════════════════════════════════════════════════════════════

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

#═══════════════════════════════════════════════════════════════════════════
# Info & Help Pages (Low Priority)
#═══════════════════════════════════════════════════════════════════════════

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

echo "Conduit v2.0 Tools Module loaded successfully."
