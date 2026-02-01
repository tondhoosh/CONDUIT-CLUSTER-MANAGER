# Conduit v2.0 Integration Guide
## Completing the Dashboard & Menu System

**Status:** Core v2.0 infrastructure complete, UI layer pending  
**Approach:** Modular integration of v1.x features into v2.0 foundation  
**Estimated Time:** 4-6 hours for full integration

---

## 🎯 Quick Assessment

### What Already Works in v2.0
✅ Nginx Layer 4 Load Balancer  
✅ System kernel tuning  
✅ Bridge networking with resource limits  
✅ Health monitoring & watchdog  
✅ Single-interface tracker  
✅ CLI commands: start, stop, restart, status, health, scale, uninstall  

### What's Missing
❌ Interactive dashboard displays (show_dashboard, show_live_stats, show_peers)  
❌ Interactive menu system (show_menu, show_settings_menu, etc.)  
❌ Telegram bot integration (setup wizard, notifications)  
❌ QR code display for multiple containers  
❌ Backup/restore functionality  

---

## 📊 Key Discovery: v1.x Already Has Multi-Container Support!

The original `conduit.sh` was designed for up to 5 containers and includes:
- **Multi-container stats aggregation** (lines 2400-2669)
- **Per-container log parsing** (lines 2420-2466)
- **Cluster-wide upload/download totals** (lines 2472-2518)
- **Resource usage across all containers** (lines 2520-2593)

**This means:** Most dashboard functions can be ported directly with minimal changes!

---

## 🔄 Integration Strategy

### Option A: Quick Integration (Recommended)
**Time:** 30-60 minutes  
**Result:** Working interactive dashboard

1. Copy utility functions from v1.x to v2.0
2. Copy dashboard functions (show_dashboard, show_live_stats, show_status)
3. Copy simple menu system (show_menu)
4. Update `main()` to call show_menu by default

**Files Needed:**
```bash
# From conduit.sh (v1.x)
- Lines 1900-2100: Utility functions (format_bytes, get_container_stats, etc.)
- Lines 2130-2367: show_dashboard(), show_live_stats(), show_peers()
- Lines 2400-2669: show_status() (✅ already adapted in v2.0!)
- Lines 5552-5726: show_menu() main menu loop
```

### Option B: Full Feature Parity
**Time:** 10-13 hours  
**Result:** Complete v1.x feature set in v2.0 architecture

1. All features from Option A
2. Settings management (change_settings, manage_containers)
3. Telegram integration (setup wizard, notifications)
4. QR code generation for all containers
5. Backup/restore with multi-container support
6. Update mechanism adapted for v2.0

---

## 🛠️ Step-by-Step Integration (Option A)

### Step 1: Add Missing Utility Functions

The v2.0 foundation is missing these helper functions from v1.x:

```bash
# Required utilities (from conduit.sh lines 1900-2100)
- format_bytes()          # Convert bytes to human-readable format
- format_number()         # Add thousands separators
- format_gb()             # Format as GB
- get_container_stats()   # Aggregate docker stats across all containers
- get_system_stats()      # Get system CPU/RAM usage
- get_cpu_cores()         # Detect CPU core count
- get_container_max_clients()    # Get max-clients for container i
- get_container_bandwidth()      # Get bandwidth for container i
- get_container_cpus()          # Get CPU limit for container i
- get_container_memory()        # Get RAM limit for container i
```

**Action:** Copy these functions from `conduit.sh` lines 1900-2100 into `conduit-v2.0.sh` after line 900 (after basic utilities section).

---

### Step 2: Add Dashboard Functions

**2A. Copy show_dashboard() - Main Status Dashboard**

```bash
# Source: conduit.sh lines 2130-2265
# Purpose: Full-screen dashboard with TOP 5 traffic charts
# Changes needed: None (already multi-container aware)
```

This function displays:
- Cluster status (containers, clients, uptime)
- Traffic totals (upload/download)
- Resource usage (CPU, RAM, Network)
- TOP 5 charts: Active Clients by Country, Top Upload Countries

**2B. Copy show_live_stats() - Real-Time Statistics**

```bash
# Source: conduit.sh lines 1990-2128
# Purpose: Auto-refreshing stats with live client counts
# Changes needed: None (already aggregates across all containers)
```

**2C. Copy show_peers() - Live Peers by Country**

```bash
# Source: conduit.sh lines 2266-2367
# Purpose: Full-screen breakdown of traffic by country
# Changes needed: None
```

**2D. show_status() - Quick Status**

```bash
# Status: ✅ Already implemented in v2.0!
# Source: conduit-v2.0.sh lines 400-500 (placeholder)
# Note: v1.x version (lines 2400-2669) is more complete
```

**Action:** Replace the placeholder `show_status()` in v2.0 with the complete version from v1.x lines 2400-2669. It already handles multi-container aggregation perfectly.

---

### Step 3: Add show_logs() Function

```bash
# Source: conduit.sh lines 2880-2975
# Purpose: View Docker logs with container selection
# Changes needed: Adapt for unlimited containers (v1.x supports 1-5, v2.0 needs 1-N)
```

**Modification required:**
```bash
# v1.x (hardcoded to 5):
for i in 1 2 3 4 5; do

# v2.0 (use CONTAINER_COUNT):
for i in $(seq 1 $CONTAINER_COUNT); do
```

---

### Step 4: Integrate Interactive Menu System

**4A. Copy show_menu() - Main Menu Loop**

```bash
# Source: conduit.sh lines 5552-5726
# Purpose: Main interactive menu
# Changes needed: 
#   - Update version display to show "v2.0 Cluster Edition"
#   - Add new menu item: "View Nginx LB Status"
```

**Menu structure (preserved from v1.x):**
```
1. 📈 View status dashboard
2. 📊 Live connection stats
3. 📋 View logs
4. 🌍 Live peers by country

5. ▶️  Start Conduit
6. ⏹️  Stop Conduit
7. 🔁 Restart Conduit
8. 🔄 Update Conduit

9. ⚙️  Settings & Tools
c. 📦 Manage containers
a. 📊 Advanced stats
i. ℹ️  Info & Help
0. 🚪 Exit
```

**New v2.0 menu items to add:**
```
n. 🔀 Nginx LB Status (show Nginx stats, health checks, backend status)
s. 🔧 System Tuning (view/reapply kernel parameters)
```

---

### Step 5: Update main() Entry Point

```bash
# Current v2.0 main() (lines 1300-1400):
case "${1:-menu}" in
    start)   [...] ;;
    stop)    [...] ;;
    menu|*)
        if [ -f "$INSTALL_DIR/settings.conf" ]; then
            echo "Management menu not yet implemented."  # ← Replace this
        else
            # First-time installation
            [...]
        fi
        ;;
esac

# Modified v2.0 main():
case "${1:-menu}" in
    start)   [...] ;;
    stop)    [...] ;;
    menu|*)
        if [ -f "$INSTALL_DIR/settings.conf" ]; then
            source "$INSTALL_DIR/settings.conf"
            show_menu  # ← Call the menu!
        else
            # First-time installation
            [...]
        fi
        ;;
esac
```

---

## 📝 Complete Integration Checklist

### Phase 1: Critical UI (1-2 hours)
- [ ] Copy utility functions (format_bytes, get_container_stats, etc.)
- [ ] Copy show_status() from v1.x (replace placeholder)
- [ ] Copy show_dashboard()
- [ ] Copy show_live_stats()
- [ ] Copy show_peers()
- [ ] Copy show_logs() (adapt for unlimited containers)
- [ ] Copy show_menu()
- [ ] Update main() to call show_menu
- [ ] Test menu navigation

### Phase 2: Container Management (1 hour)
- [ ] Copy manage_containers() function
- [ ] Copy show_container_menu()
- [ ] Adapt for unlimited container count (remove hardcoded limit of 5)
- [ ] Test scaling up/down from menu

### Phase 3: Settings Management (1 hour)
- [ ] Copy change_settings() function
- [ ] Copy change_resource_limits()
- [ ] Copy set_data_cap()
- [ ] Copy show_settings_menu()
- [ ] Test per-container settings

### Phase 4: Telegram Integration (2 hours)
- [ ] Copy telegram_setup_wizard()
- [ ] Copy telegram_generate_notify_script()
- [ ] Copy telegram_test_message(), telegram_get_chat_id()
- [ ] Copy show_telegram_menu()
- [ ] Update health monitoring to use Telegram alerts
- [ ] Test bot setup and notifications

### Phase 5: QR Codes & Backup (1 hour)
- [ ] Copy show_qr_code() (adapt for unlimited containers)
- [ ] Copy get_conduit_id()
- [ ] Copy backup_key(), restore_key()
- [ ] Test multi-container QR generation

### Phase 6: Update Mechanism (1 hour)
- [ ] Copy update_conduit() function
- [ ] Copy recreate_containers()
- [ ] Add v2.0 awareness (check for Nginx, system tuning)
- [ ] Test update flow

### Phase 7: Info & Help (30 min)
- [ ] Copy show_info_menu() and all _info_* functions
- [ ] Copy show_about()
- [ ] Update text to reference v2.0 features
- [ ] Test help pages

---

## 🚀 Quick Start Script

For rapid integration, here's a bash script to extract and merge functions:

```bash
#!/bin/bash
# v2.0-integration.sh - Quick integration helper

V1_SCRIPT="conduit.sh"
V2_SCRIPT="conduit-v2.0.sh"
OUTPUT="conduit-v2.0-complete.sh"

echo "Merging v1.x UI into v2.0 foundation..."

# Copy v2.0 foundation (infrastructure)
cp "$V2_SCRIPT" "$OUTPUT"

# Extract and append utility functions from v1.x
sed -n '1900,2100p' "$V1_SCRIPT" >> "$OUTPUT"

# Extract and append dashboard functions
sed -n '1990,2367p' "$V1_SCRIPT" >> "$OUTPUT"

# Extract and append show_status (replace placeholder)
# (Manual merge required - check for duplicates)

# Extract and append menu system
sed -n '5552,5726p' "$V1_SCRIPT" >> "$OUTPUT"

# Extract and append info/help system
sed -n '5728,5903p' "$V1_SCRIPT" >> "$OUTPUT"

echo "✓ Merged! Manual cleanup required:"
echo "  1. Remove duplicate functions"
echo "  2. Update main() to call show_menu"
echo "  3. Adapt container loops for unlimited containers"
echo "  4. Test thoroughly"
```

---

## 🎨 v2.0-Specific Enhancements

### New Functions to Add (Not in v1.x)

**1. show_nginx_status() - Nginx Load Balancer Dashboard**

```bash
show_nginx_status() {
    clear
    print_header
    echo -e "${CYAN}═══ NGINX LOAD BALANCER STATUS ═══${NC}"
    echo ""
    
    # Nginx service status
    echo -e "${BOLD}Service Status:${NC}"
    if systemctl is-active nginx &>/dev/null; then
        echo -e "  Nginx:        ${GREEN}Running${NC}"
    else
        echo -e "  Nginx:        ${RED}Stopped${NC}"
        return
    fi
    
    # Configuration test
    if nginx -t 2>/dev/null; then
        echo -e "  Config:       ${GREEN}Valid${NC}"
    else
        echo -e "  Config:       ${RED}Invalid${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}Backend Status:${NC}"
    for i in $(seq 1 $CONTAINER_COUNT); do
        local cname=$(get_container_name $i)
        local port=$((BACKEND_PORT_START + i - 1))
        
        if docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
            echo -e "  ${cname} (127.0.0.1:${port}):  ${GREEN}UP${NC}"
        else
            echo -e "  ${cname} (127.0.0.1:${port}):  ${RED}DOWN${NC}"
        fi
    done
    
    echo ""
    echo -e "${BOLD}Connection Statistics:${NC}"
    
    # Parse Nginx access log for connection stats (last 100 lines)
    if [ -f /var/log/nginx/conduit-stream-access.log ]; then
        local total_conn=$(wc -l < /var/log/nginx/conduit-stream-access.log)
        local recent_conn=$(tail -100 /var/log/nginx/conduit-stream-access.log | wc -l)
        echo -e "  Total connections:  $(format_number $total_conn)"
        echo -e "  Recent (last 100):  $(format_number $recent_conn)"
    else
        echo -e "  ${YELLOW}No logs yet${NC}"
    fi
    
    echo ""
    read -n 1 -s -r -p "Press any key to return..." < /dev/tty || true
}
```

**2. show_system_tuning() - View/Reapply Kernel Parameters**

```bash
show_system_tuning() {
    clear
    print_header
    echo -e "${CYAN}═══ SYSTEM KERNEL TUNING ═══${NC}"
    echo ""
    
    if [ ! -f /etc/sysctl.d/99-conduit-cluster.conf ]; then
        echo -e "${YELLOW}System tuning not applied yet.${NC}"
        echo ""
        read -p "Apply tuning now? [y/N]: " apply < /dev/tty || true
        if [[ "$apply" =~ ^[Yy]$ ]]; then
            tune_system
        fi
        return
    fi
    
    echo -e "${BOLD}Current Kernel Parameters:${NC}"
    echo ""
    
    # Display key parameters
    echo -e "  ${CYAN}TCP/Network:${NC}"
    echo -e "    somaxconn:          $(sysctl -n net.core.somaxconn 2>/dev/null || echo 'N/A')"
    echo -e "    tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || echo 'N/A')"
    echo -e "    tcp_congestion:     $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
    
    echo ""
    echo -e "  ${CYAN}File Descriptors:${NC}"
    echo -e "    fs.file-max:        $(sysctl -n fs.file-max 2>/dev/null || echo 'N/A')"
    
    echo ""
    echo -e "  ${CYAN}Connection Tracking:${NC}"
    echo -e "    nf_conntrack_max:   $(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 'N/A')"
    
    echo ""
    echo -e "${BOLD}Options:${NC}"
    echo -e "  r. Reapply tuning (reload from config)"
    echo -e "  v. View full config file"
    echo -e "  b. Back"
    echo ""
    
    read -p "Choice: " choice < /dev/tty || return
    case "$choice" in
        r|R)
            echo "Reapplying tuning..."
            sysctl -p /etc/sysctl.d/99-conduit-cluster.conf
            echo -e "${GREEN}✓ Tuning reapplied${NC}"
            read -n 1 -s -r -p "Press any key..." < /dev/tty || true
            ;;
        v|V)
            less /etc/sysctl.d/99-conduit-cluster.conf
            ;;
    esac
}
```

---

## 🔍 Testing Procedure

After integration, test in this order:

### 1. Basic UI Test
```bash
sudo bash conduit-v2.0-complete.sh menu
# Should show interactive menu, not "not yet implemented"
```

### 2. Dashboard Test
```bash
conduit menu
> 1  # View status dashboard
# Should show cluster stats with multi-container aggregation
```

### 3. Live Stats Test
```bash
conduit menu
> 2  # Live connection stats
# Should auto-refresh every 3 seconds
# Press 'q' to exit
```

### 4. Logs Test
```bash
conduit menu
> 3  # View logs
# Should show log viewer with container selection
```

### 5. Container Management Test
```bash
conduit menu
> c  # Manage containers
> a  # Add container
# Should scale from 8 to 9 containers
# Nginx config should auto-regenerate
```

### 6. Settings Test
```bash
conduit menu
> 9  # Settings & Tools
> 1  # Change settings
# Should allow per-container configuration
```

---

## 📦 Pre-Built Integration Package

I can provide a complete integrated script if you prefer. The integration approach above gives you control over which features to add, but here's what a complete package would include:

**conduit-v2.0-complete.sh** (estimated 5000-6000 lines):
- ✅ All v2.0 core infrastructure
- ✅ All v1.x dashboard & menu functions
- ✅ Adapted for unlimited container scaling
- ✅ v2.0-specific enhancements (Nginx status, tuning viewer)
- ✅ Full Telegram integration
- ✅ Complete QR code support
- ✅ Backup/restore functionality

**Would you like me to create this complete integrated script?**

---

## 🎯 Minimal Working Extension (Fastest Path)

If you want the fastest path to a working interactive interface, here's what to add to `conduit-v2.0.sh`:

**Minimum Required (30 minutes):**
1. **Utility functions** (10 lines): format_bytes, get_container_stats
2. **show_status()** (80 lines): Already aggregates multi-container stats
3. **show_menu()** (100 lines): Basic menu loop calling status/start/stop
4. **Update main()** (5 lines): Call show_menu instead of placeholder

**Result:** Working interactive menu with status display

**Next Priority (30 minutes):**
1. **show_logs()** (50 lines): Log viewer
2. **show_dashboard()** (150 lines): Full dashboard with charts

**Result:** Complete basic user experience

---

## 🤔 Decision Point

**Choose your path:**

**A. I'll integrate manually** (using this guide)
- Gives you full control
- Learn the codebase deeply
- Estimated time: 4-6 hours

**B. Create minimal working extension** (~200 lines to add)
- Fastest to working UI
- Can expand later
- Estimated time: 1 hour

**C. Generate complete integrated script** (~5500 lines)
- Everything in one file
- Ready to deploy
- Requires careful testing

**Which approach would you like me to help with?**
