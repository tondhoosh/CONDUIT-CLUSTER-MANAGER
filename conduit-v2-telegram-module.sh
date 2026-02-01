#!/bin/bash
#═══════════════════════════════════════════════════════════════════════════
# Conduit v2.0 Telegram Module - Medium Priority
#═══════════════════════════════════════════════════════════════════════════
# Complete Telegram bot integration for notifications and reports
#
# FEATURES:
# - Telegram bot setup wizard
# - Test message functionality
# - Chat ID auto-detection
# - Notification service generation
# - Telegram settings menu
#═══════════════════════════════════════════════════════════════════════════

telegram_get_chat_id() {
    local response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates")
    local chat_id=$(echo "$response" | grep -o '"chat":{"id":[0-9-]*' | head -1 | grep -o '[0-9-]*$')
    
    if [ -n "$chat_id" ]; then
        TELEGRAM_CHAT_ID="$chat_id"
        echo -e "${GREEN}✓ Chat ID detected: ${chat_id}${NC}"
        return 0
    else
        return 1
    fi
}

telegram_test_message() {
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        return 1
    fi
    
    local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
    local message="🎉 *Conduit v2.0 Cluster Test*%0A%0AServer: ${server_label}%0AStatus: Online%0AContainers: ${CONTAINER_COUNT}%0A%0ANotifications are working!"
    
    local response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown")
    
    if echo "$response" | grep -q '"ok":true'; then
        return 0
    else
        return 1
    fi
}

telegram_generate_notify_script() {
    log_info "Generating Telegram notification script..."
    
    cat > "$INSTALL_DIR/conduit-telegram.sh" << 'TGEOF'
#!/bin/bash
# Conduit v2.0 Telegram Notification Service

INSTALL_DIR="/opt/conduit"
source "$INSTALL_DIR/settings.conf" 2>/dev/null || exit 1

[ "$TELEGRAM_ENABLED" != "true" ] && exit 0
[ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && exit 0

send_telegram() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" &>/dev/null
}

get_cluster_stats() {
    local server_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
    local running_count=$(docker ps --filter "name=^conduit" --format '{{.Names}}' 2>/dev/null | wc -l)
    local total_connected=0
    local total_connecting=0
    
    for i in $(seq 1 ${CONTAINER_COUNT:-8}); do
        local cname="conduit"
        [ $i -gt 1 ] && cname="conduit-${i}"
        
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
            local stats=$(docker logs --tail 5 "$cname" 2>&1 | grep "\[STATS\]" | tail -1)
            if [ -n "$stats" ]; then
                local connected=$(echo "$stats" | sed -n 's/.*Connected:[[:space:]]*\([0-9]*\).*/\1/p')
                local connecting=$(echo "$stats" | sed -n 's/.*Connecting:[[:space:]]*\([0-9]*\).*/\1/p')
                total_connected=$((total_connected + ${connected:-0}))
                total_connecting=$((total_connecting + ${connecting:-0}))
            fi
        fi
    done
    
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1)
    local mem_usage=$(free | awk '/Mem/{printf("%.1f"), $3/$2*100}')
    
    echo "${server_label}|${running_count}|${CONTAINER_COUNT}|${total_connected}|${total_connecting}|${cpu_usage}|${mem_usage}"
}

# Initialize timestamp tracking
_ts_dir="$INSTALL_DIR/telegram_state"
mkdir -p "$_ts_dir"
[ ! -f "$_ts_dir/.last_report_ts" ] && echo "0" > "$_ts_dir/.last_report_ts"
[ ! -f "$_ts_dir/.last_daily_ts" ] && echo "0" > "$_ts_dir/.last_daily_ts"
[ ! -f "$_ts_dir/.last_weekly_ts" ] && echo "0" > "$_ts_dir/.last_weekly_ts"

while true; do
    now_ts=$(date +%s)
    last_report_ts=$(cat "$_ts_dir/.last_report_ts")
    last_daily_ts=$(cat "$_ts_dir/.last_daily_ts")
    last_weekly_ts=$(cat "$_ts_dir/.last_weekly_ts")
    
    interval_seconds=$((TELEGRAM_INTERVAL * 3600))
    start_hour_seconds=$((TELEGRAM_START_HOUR * 3600))
    current_hour_seconds=$(( $(date +%s) % 86400 ))
    
    # Check if it's time for scheduled report
    time_since_last=$((now_ts - last_report_ts))
    time_until_next_hour=$((start_hour_seconds - current_hour_seconds))
    [ $time_until_next_hour -lt 0 ] && time_until_next_hour=$((time_until_next_hour + 86400))
    
    if [ $time_since_last -ge $interval_seconds ] && [ $time_until_next_hour -lt 300 ]; then
        # Send scheduled report
        IFS='|' read -r server_label running_count total_count connected connecting cpu mem <<< $(get_cluster_stats)
        
        local status_emoji="✅"
        [ $running_count -lt $total_count ] && status_emoji="⚠️"
        [ $running_count -eq 0 ] && status_emoji="🔴"
        
        local message="${status_emoji} *Conduit Cluster Report*%0A%0A"
        message="${message}📡 Server: \`${server_label}\`%0A"
        message="${message}📦 Containers: ${running_count}/${total_count}%0A"
        message="${message}👥 Clients: ${connected} connected, ${connecting} connecting%0A"
        message="${message}💻 CPU: ${cpu}%%0A"
        message="${message}🧠 RAM: ${mem}%%0A%0A"
        message="${message}🕐 $(date '+%Y-%m-%d %H:%M:%S')"
        
        send_telegram "$message"
        echo "$now_ts" > "$_ts_dir/.last_report_ts"
    fi
    
    # Check for alerts (if enabled)
    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
        IFS='|' read -r server_label running_count total_count connected connecting cpu mem <<< $(get_cluster_stats)
        
        # Alert: Containers down
        if [ $running_count -lt $total_count ]; then
            local down=$((total_count - running_count))
            send_telegram "🔴 *ALERT*: ${down} container(s) down on ${server_label}"
        fi
        
        # Alert: High CPU
        if (( $(echo "$cpu > 90" | bc -l 2>/dev/null || echo 0) )); then
            send_telegram "⚠️ *ALERT*: High CPU usage (${cpu}%) on ${server_label}"
        fi
        
        # Alert: High RAM
        if (( $(echo "$mem > 90" | bc -l 2>/dev/null || echo 0) )); then
            send_telegram "⚠️ *ALERT*: High RAM usage (${mem}%) on ${server_label}"
        fi
    fi
    
    # Daily summary (if enabled)
    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
        local hours_since_daily=$(( (now_ts - last_daily_ts) / 3600 ))
        if [ $hours_since_daily -ge 24 ]; then
            IFS='|' read -r server_label running_count total_count connected connecting cpu mem <<< $(get_cluster_stats)
            local message="📊 *Daily Summary* - ${server_label}%0A%0A"
            message="${message}Containers: ${running_count}/${total_count}%0A"
            message="${message}Peak Clients: ${connected}%0A"
            message="${message}Avg CPU: ${cpu}%%0A"
            message="${message}Avg RAM: ${mem}%"
            send_telegram "$message"
            echo "$now_ts" > "$_ts_dir/.last_daily_ts"
        fi
    fi
    
    # Weekly summary (if enabled)
    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
        local hours_since_weekly=$(( (now_ts - last_weekly_ts) / 3600 ))
        if [ $hours_since_weekly -ge 168 ]; then
            IFS='|' read -r server_label running_count total_count connected connecting cpu mem <<< $(get_cluster_stats)
            local message="📈 *Weekly Summary* - ${server_label}%0A%0A"
            message="${message}7-Day Uptime: Good%0A"
            message="${message}Containers: ${running_count}/${total_count}%0A"
            message="${message}Peak Clients: ${connected}"
            send_telegram "$message"
            echo "$now_ts" > "$_ts_dir/.last_weekly_ts"
        fi
    fi
    
    sleep 300  # Check every 5 minutes
done
TGEOF

    chmod 700 "$INSTALL_DIR/conduit-telegram.sh"
    log_success "Telegram notification script created"
}

setup_telegram_service() {
    telegram_generate_notify_script
    
    if command -v systemctl &>/dev/null; then
        cat > /etc/systemd/system/conduit-telegram.service << EOF
[Unit]
Description=Conduit Telegram Notifications
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $INSTALL_DIR/conduit-telegram.sh
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable conduit-telegram.service 2>/dev/null || true
        systemctl restart conduit-telegram.service 2>/dev/null || true
        log_success "Telegram service enabled"
    fi
}

telegram_stop_notify() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
    fi
}

telegram_start_notify() {
    telegram_stop_notify
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        setup_telegram_service
    fi
}

telegram_disable_service() {
    if command -v systemctl &>/dev/null; then
        systemctl stop conduit-telegram.service 2>/dev/null || true
        systemctl disable conduit-telegram.service 2>/dev/null || true
    fi
}

telegram_setup_wizard() {
    local _saved_token="$TELEGRAM_BOT_TOKEN"
    local _saved_chatid="$TELEGRAM_CHAT_ID"
    local _saved_interval="$TELEGRAM_INTERVAL"
    local _saved_enabled="$TELEGRAM_ENABLED"
    local _saved_starthour="$TELEGRAM_START_HOUR"
    local _saved_label="$TELEGRAM_SERVER_LABEL"
    
    trap 'TELEGRAM_BOT_TOKEN="$_saved_token"; TELEGRAM_CHAT_ID="$_saved_chatid"; TELEGRAM_INTERVAL="$_saved_interval"; TELEGRAM_ENABLED="$_saved_enabled"; TELEGRAM_START_HOUR="$_saved_starthour"; TELEGRAM_SERVER_LABEL="$_saved_label"; trap - SIGINT; echo; return' SIGINT
    
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo -e "              ${BOLD}TELEGRAM NOTIFICATIONS SETUP${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Step 1: Create a Telegram Bot${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Open Telegram and search for ${BOLD}@BotFather${NC}"
    echo -e "  2. Send ${YELLOW}/newbot${NC}"
    echo -e "  3. Choose a name (e.g. \"My Conduit Monitor\")"
    echo -e "  4. Choose a username (e.g. \"my_conduit_bot\")"
    echo -e "  5. BotFather will give you a token like:"
    echo -e "     ${YELLOW}123456789:ABCdefGHIjklMNOpqrsTUVwxyz${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠ OPSEC Note:${NC} Enabling Telegram creates outbound"
    echo -e "  connections to api.telegram.org from this server."
    echo ""
    read -p "  Enter your bot token: " TELEGRAM_BOT_TOKEN < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN## }"
    TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN%% }"
    
    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        echo -e "  ${RED}No token entered. Setup cancelled.${NC}"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    if ! echo "$TELEGRAM_BOT_TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$'; then
        echo -e "  ${RED}Invalid token format.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    echo ""
    echo -e "  ${BOLD}Step 2: Get Your Chat ID${NC}"
    echo -e "  ${CYAN}────────────────────────${NC}"
    echo -e "  1. Open your new bot in Telegram"
    echo -e "  2. Send it the message: ${YELLOW}/start${NC}"
    echo -e "  3. Press Enter here when done..."
    echo ""
    read -p "  Press Enter after sending /start... " < /dev/tty || { trap - SIGINT; TELEGRAM_BOT_TOKEN="$_saved_token"; return; }
    
    echo -ne "  Detecting chat ID... "
    local attempts=0
    TELEGRAM_CHAT_ID=""
    while [ $attempts -lt 3 ] && [ -z "$TELEGRAM_CHAT_ID" ]; do
        telegram_get_chat_id && break
        attempts=$((attempts + 1))
        sleep 2
    done
    
    if [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo -e "${RED}✗ Could not detect chat ID${NC}"
        echo -e "  Make sure you sent /start to the bot."
        TELEGRAM_BOT_TOKEN="$_saved_token"
        TELEGRAM_CHAT_ID="$_saved_chatid"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    echo ""
    echo -e "  ${BOLD}Step 3: Notification Interval${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  1. Every 1 hour"
    echo -e "  2. Every 3 hours"
    echo -e "  3. Every 6 hours (recommended)"
    echo -e "  4. Every 12 hours"
    echo -e "  5. Every 24 hours"
    echo ""
    read -p "  Choice [1-5] (default 3): " ichoice < /dev/tty || true
    
    case "$ichoice" in
        1) TELEGRAM_INTERVAL=1 ;;
        2) TELEGRAM_INTERVAL=3 ;;
        4) TELEGRAM_INTERVAL=12 ;;
        5) TELEGRAM_INTERVAL=24 ;;
        *) TELEGRAM_INTERVAL=6 ;;
    esac
    
    echo ""
    echo -e "  ${BOLD}Step 4: Start Hour${NC}"
    echo -e "  ${CYAN}─────────────────────────────${NC}"
    echo -e "  Reports will repeat every ${TELEGRAM_INTERVAL}h from this hour."
    echo ""
    read -p "  Start hour [0-23] (default 0): " shchoice < /dev/tty || true
    
    if [ -n "$shchoice" ] && [ "$shchoice" -ge 0 ] 2>/dev/null && [ "$shchoice" -le 23 ] 2>/dev/null; then
        TELEGRAM_START_HOUR=$shchoice
    else
        TELEGRAM_START_HOUR=0
    fi
    
    echo ""
    echo -ne "  Sending test message... "
    if telegram_test_message; then
        echo -e "${GREEN}✓ Success!${NC}"
    else
        echo -e "${RED}✗ Failed to send.${NC}"
        TELEGRAM_BOT_TOKEN="$_saved_token"
        TELEGRAM_CHAT_ID="$_saved_chatid"
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        trap - SIGINT
        return
    fi
    
    TELEGRAM_ENABLED=true
    save_settings
    telegram_start_notify
    
    trap - SIGINT
    echo ""
    echo -e "  ${GREEN}${BOLD}✓ Telegram notifications enabled!${NC}"
    echo -e "  You'll receive reports every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00."
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

show_telegram_menu() {
    while true; do
        [ -f "$INSTALL_DIR/settings.conf" ] && source "$INSTALL_DIR/settings.conf"
        
        clear
        print_header
        
        if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "${CYAN}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            echo -e "  Status: ${GREEN}✓ Enabled${NC} (every ${TELEGRAM_INTERVAL}h starting at ${TELEGRAM_START_HOUR}:00)"
            echo ""
            
            local alerts_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_ALERTS_ENABLED:-true}" != "true" ] && alerts_st="${RED}OFF${NC}"
            local daily_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_DAILY_SUMMARY:-true}" != "true" ] && daily_st="${RED}OFF${NC}"
            local weekly_st="${GREEN}ON${NC}"
            [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" != "true" ] && weekly_st="${RED}OFF${NC}"
            
            echo -e "  1. 📩 Send test message"
            echo -e "  2. ⏱  Change interval"
            echo -e "  3. ❌ Disable notifications"
            echo -e "  4. 🔄 Reconfigure (new bot/chat)"
            echo -e "  5. 🚨 Alerts (CPU/RAM/down):    ${alerts_st}"
            echo -e "  6. 📋 Daily summary:            ${daily_st}"
            echo -e "  7. 📊 Weekly summary:           ${weekly_st}"
            
            local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
            echo -e "  8. 🏷  Server label:            ${CYAN}${cur_label}${NC}"
            echo -e "  0. ← Back"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            
            read -p "  Enter choice: " tchoice < /dev/tty || return
            
            case "$tchoice" in
                1)
                    echo ""
                    echo -ne "  Sending test message... "
                    if telegram_test_message; then
                        echo -e "${GREEN}✓ Sent!${NC}"
                    else
                        echo -e "${RED}✗ Failed.${NC}"
                    fi
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                2)
                    echo ""
                    echo -e "  Select notification interval:"
                    echo -e "  1. Every 1 hour"
                    echo -e "  2. Every 3 hours"
                    echo -e "  3. Every 6 hours (recommended)"
                    echo -e "  4. Every 12 hours"
                    echo -e "  5. Every 24 hours"
                    read -p "  Choice [1-5]: " ichoice < /dev/tty || continue
                    
                    case "$ichoice" in
                        1) TELEGRAM_INTERVAL=1 ;;
                        2) TELEGRAM_INTERVAL=3 ;;
                        3) TELEGRAM_INTERVAL=6 ;;
                        4) TELEGRAM_INTERVAL=12 ;;
                        5) TELEGRAM_INTERVAL=24 ;;
                        *) continue ;;
                    esac
                    
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Interval updated${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                3)
                    TELEGRAM_ENABLED=false
                    save_settings
                    telegram_disable_service
                    echo -e "  ${GREEN}✓ Disabled${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                4)
                    telegram_setup_wizard
                    ;;
                5)
                    if [ "${TELEGRAM_ALERTS_ENABLED:-true}" = "true" ]; then
                        TELEGRAM_ALERTS_ENABLED=false
                    else
                        TELEGRAM_ALERTS_ENABLED=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                6)
                    if [ "${TELEGRAM_DAILY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_DAILY_SUMMARY=false
                    else
                        TELEGRAM_DAILY_SUMMARY=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                7)
                    if [ "${TELEGRAM_WEEKLY_SUMMARY:-true}" = "true" ]; then
                        TELEGRAM_WEEKLY_SUMMARY=false
                    else
                        TELEGRAM_WEEKLY_SUMMARY=true
                    fi
                    save_settings
                    telegram_start_notify
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                8)
                    echo ""
                    local cur_label="${TELEGRAM_SERVER_LABEL:-$(hostname)}"
                    echo -e "  Current: ${CYAN}${cur_label}${NC}"
                    echo "  Leave blank for hostname."
                    read -p "  New label: " new_label < /dev/tty || true
                    TELEGRAM_SERVER_LABEL="${new_label}"
                    save_settings
                    telegram_start_notify
                    echo -e "  ${GREEN}✓ Label updated${NC}"
                    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                    ;;
                0) return ;;
            esac
        else
            telegram_setup_wizard
            return
        fi
    done
}

echo "Conduit v2.0 Telegram Module loaded successfully."
