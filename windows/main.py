import subprocess
import re
import psutil
import geoip2.database
import time
import threading
import os
import sys
import requests
from rich.live import Live
from rich.table import Table
from rich.console import Console
from rich.panel import Panel
from rich.align import Align
from rich.text import Text
from rich.columns import Columns
from collections import Counter
from rich.progress import Progress, BarColumn, TextColumn, DownloadColumn

# تنظیمات مسیرها
if getattr(sys, 'frozen', False):
    BASE_DIR = sys._MEIPASS
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

CONDUIT_EXE = "conduit-windows-amd64.exe"
CONDUIT_URL = "https://github.com/Psiphon-Inc/conduit/releases/download/release-cli-1.2.0/conduit-windows-amd64.exe"
# لینک مستقیم برای دانلود دیتابیس GeoIP
GEOIP_DB = "GeoLite2-Country.mmdb"
GEOIP_URL = "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb"
DB_FILENAMES = [GEOIP_DB, 'GeoLite2-City.mmdb']
USER_TIMEOUT = 45 

APP_LOGO = """
 ██████╗  ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗
██╔════╝ ██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝
██║  ███╗██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║   
██║   ██║██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║   
╚██████╔╝╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝╚██████╔╝   
 ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝  ╚═════╝    
      CLI BY GOODZILAH | WINDOWS NATIVE MONITOR
"""

active_users = {} 
geo_cache = {}    
lock = threading.Lock()
conduit_ports = set()
console = Console()
user_limit = 50
bandwidth_limit = 40.0

def download_asset(file_name, url):
    """تابع عمومی برای دانلود فایل‌های مورد نیاز"""
    if os.path.exists(file_name):
        return

    console.print(Panel(f"[bold yellow]{file_name} missing![/bold yellow]\nDownloading from official source...", title="Setup"))
    try:
        with requests.get(url, stream=True) as r:
            r.raise_for_status()
            total_size = int(r.headers.get('content-length', 0))
            with Progress(
                TextColumn("[progress.description]{task.description}"),
                BarColumn(),
                DownloadColumn(),
                transient=True,
            ) as progress:
                task = progress.add_task(f"Fetching {file_name}...", total=total_size)
                with open(file_name, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        f.write(chunk)
                        progress.update(task, advance=len(chunk))
        console.print(f"[bold green]✓ {file_name} downloaded successfully.[/bold green]\n")
    except Exception as e:
        console.print(f"[bold red]FATAL ERROR downloading {file_name}: {e}[/bold red]")
        sys.exit(1)

# لود کردن دیتابیس GeoIP (ابتدا چک می‌کند و اگر نبود دانلود می‌کند)
download_asset(GEOIP_DB, GEOIP_URL)

reader = None
for db_name in DB_FILENAMES:
    path = os.path.join(BASE_DIR, db_name)
    if os.path.exists(path):
        try:
            reader = geoip2.database.Reader(path)
            break
        except: continue

def download_conduit():
    """دانلود خودکار فایل اجرایی از ریپو رسمی سایفون"""
    download_asset(CONDUIT_EXE, CONDUIT_URL)

def check_conduit_status():
    for proc in psutil.process_iter(['name']):
        if CONDUIT_EXE in proc.info['name'].lower():
            return True, proc.info['name']
    return False, "Not Running"

def get_conduit_ports():
    ports = set()
    for proc in psutil.process_iter(['name']):
        if CONDUIT_EXE in proc.info['name'].lower():
            try:
                for conn in proc.net_connections(kind='udp'):
                    if conn.laddr: ports.add(conn.laddr.port)
            except: continue
    return ports

def get_country(ip):
    if ip in geo_cache: return geo_cache[ip]
    if reader:
        try:
            try: res = reader.country(ip)
            except: res = reader.city(ip)
            name = res.country.name if res.country.name else "Unknown"
            geo_cache[ip] = name
            return name
        except: return "Unknown"
    return "No DB"

def pktmon_sniffer():
    global conduit_ports
    subprocess.run(["pktmon", "stop"], capture_output=True)
    subprocess.run(["pktmon", "filter", "remove"], capture_output=True)
    
    if os.path.exists("PktMon.etl"):
        try: os.remove("PktMon.etl")
        except: pass

    while True:
        conduit_ports = get_conduit_ports()
        if conduit_ports:
            for port in conduit_ports:
                subprocess.run(["pktmon", "filter", "add", "-p", str(port)], capture_output=True)
            break
        time.sleep(2)
    
    cmd = ["pktmon", "start", "--capture", "--log-mode", "real-time", "--file-size", "8"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8')
    pattern = r"(\d{1,3}(?:\.\d{1,3}){3})\.\d+\s+>\s+[\d\.]+\.(\d+):\s+UDP,\s+length\s+(\d+)"

    for line in process.stdout:
        match = re.search(pattern, line)
        if match:
            src_ip, dst_port, size = match.group(1), int(match.group(2)), int(match.group(3))
            if dst_port in conduit_ports and not src_ip.startswith(('127.', '192.', '10.', '172.')):
                with lock:
                    now = time.time()
                    if src_ip not in active_users:
                        active_users[src_ip] = {'country': get_country(src_ip), 'total_bytes': 0, 'last_bytes': 0, 'speed': 0, 'last_update': now, 'last_seen': now}
                    u = active_users[src_ip]
                    u['total_bytes'] += size
                    u['last_bytes'] += size
                    u['last_seen'] = now
                    if now - u['last_update'] >= 1.0:
                        u['speed'] = u['last_bytes'] / (now - u['last_update'])
                        u['last_bytes'] = 0
                        u['last_update'] = now

def format_bytes(size):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size < 1024: return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"

def mask_ip(ip):
    parts = ip.split('.')
    return f"{parts[0]}.***.***.***" if len(parts) == 4 else ip

def show_monitoring():
    with Live(auto_refresh=False, console=console, screen=True) as live:
        try:
            while True:
                term_height = console.size.height
                available_rows = max(5, term_height - 20)
                now = time.time()
                with lock:
                    u_table = Table(title=Text("LIVE USER TRAFFIC", style="bold white on blue"), expand=True, border_style="cyan")
                    u_table.add_column("IP Address", style="bold white")
                    u_table.add_column("Country", style="bold green")
                    u_table.add_column("Speed", style="bold yellow")
                    u_table.add_column("Total Data", style="bold blue")
                    u_table.add_column("Last Seen", justify="right", style="dim")
                    
                    sorted_users = sorted(active_users.items(), key=lambda x: x[1]['last_seen'], reverse=True)
                    for ip, d in sorted_users[:available_rows]:
                        u_table.add_row(mask_ip(ip), d['country'], f"{format_bytes(d['speed'])}/s", format_bytes(d['total_bytes']), f"{int(now - d['last_seen'])}s ago")

                    c_stats = {}
                    for d in active_users.values():
                        c = d['country']
                        c_stats[c] = c_stats.get(c, {'n': 0, 'v': 0})
                        c_stats[c]['n'] += 1
                        c_stats[c]['v'] += d['total_bytes']
                    
                    s_table = Table(title=Text("GEOGRAPHICAL DISTRIBUTION", style="bold white on magenta"), expand=True, border_style="magenta")
                    s_table.add_column("Country", style="white")
                    s_table.add_column("Active Users", justify="center", style="bold green")
                    s_table.add_column("Total Consumption", justify="right", style="bold yellow")
                    for c, s in c_stats.items():
                        s_table.add_row(c, str(s['n']), format_bytes(s['v']))

                header = Panel(Text(f"CONDUIT MONITORING | ONLINE: {len(active_users)} | LIMIT: {user_limit}", justify="center", style="bold yellow"))
                grid = Table.grid(expand=True)
                grid.add_row(header)
                grid.add_row(u_table)
                grid.add_row(s_table)
                grid.add_row(Align.center("\n[blink bold red]PRESS CTRL+C TO RETURN TO MAIN MENU[/blink bold red]"))
                
                live.update(grid, refresh=True)
                time.sleep(1)
        except KeyboardInterrupt: pass

def get_selection(title, options):
    while True:
        os.system('cls')
        console.print(Align.center(Text(APP_LOGO, style="bold cyan")))
        console.print(Panel(Align.center(f"[bold white]{title}[/bold white]"), border_style="yellow"))
        for i, opt in enumerate(options, 1):
            console.print(f"    [bold yellow]{i}.[/bold yellow] [bold white]{opt}[/bold white]")
        try:
            line_input = input("\n    Select an option: ")
            choice = int(line_input)
            if 1 <= choice <= len(options): return options[choice-1]
        except: pass

def main_menu():
    global user_limit, bandwidth_limit
    while True:
        os.system('cls')
        is_running, _ = check_conduit_status()
        status_color = "green" if is_running else "red"
        status_text = "ONLINE" if is_running else "OFFLINE"
        
        console.print(Align.center(Text(APP_LOGO, style="bold gradient cyan to blue")))
        
        info_grid = Table.grid(expand=True)
        info_grid.add_column(justify="center")
        info_grid.add_row(
            Panel(
                f"[bold white]STATUS:[/bold white] [{status_color} bold]{status_text}[/{status_color} bold]\n"
                f"[bold white]LIMITS:[/bold white] [cyan]{user_limit} Users[/cyan] | [magenta]{bandwidth_limit} Mbps[/magenta]",
                title="[bold yellow]System Information[/bold yellow]",
                border_style="blue",
                expand=False
            )
        )
        console.print(Align.center(info_grid))
        
        print("\n")
        menu_table = Table.grid(padding=(0, 4))
        menu_table.add_row("[bold yellow]1.[/bold yellow] Start Conduit Service", "[bold yellow]2.[/bold yellow] Open Monitoring Console")
        menu_table.add_row("[bold yellow]3.[/bold yellow] Stop Conduit Service", "[bold yellow]4.[/bold yellow] System Settings")
        menu_table.add_row("[bold yellow]5.[/bold yellow] Terminate App", "")
        console.print(Align.center(menu_table))
        
        cmd = input("\n    Enter Command: ")
        if cmd == '1':
            if not is_running:
                download_conduit()
                conduit_path = os.path.join(os.getcwd(), CONDUIT_EXE)
                run_cmd = f'"{conduit_path}" start -m {user_limit} -b {float(bandwidth_limit)} -v --metrics-addr 127.0.0.1:9090'
                subprocess.Popen(run_cmd, creationflags=subprocess.CREATE_NEW_CONSOLE)
                console.print(f"    [bold green]Launching Official Conduit Service...[/bold green]")
                time.sleep(2)
        elif cmd == '2':
            if is_running: show_monitoring()
            else: console.print("    [bold red]Error: Conduit is not running![/bold red]"); time.sleep(1.5)
        elif cmd == '3':
            subprocess.run(["taskkill", "/f", "/im", CONDUIT_EXE], capture_output=True)
            console.print("    [bold red]Service Stopped.[/bold red]"); time.sleep(1)
        elif cmd == '4':
            user_limit = get_selection("USER LIMIT CONFIGURATION", [50, 100, 200, 500, 1000])
            bandwidth_limit = get_selection("BANDWIDTH CONFIGURATION (MBPS)", [40, 100, 200, 500, 1000])
        elif cmd == '5':
            subprocess.run(["pktmon", "stop"], capture_output=True)
            console.print("[bold red]Exiting...[/bold red]")
            break

if __name__ == "__main__":
    os.system(f"title GOOZILAH MONITORING DASHBOARD")
    
    user_limit = get_selection("INITIAL SETUP: USER LIMIT", [50, 100, 200, 500])
    bandwidth_limit = get_selection("INITIAL SETUP: BANDWIDTH", [40, 100, 200, 500, 1000])
    
    threading.Thread(target=pktmon_sniffer, daemon=True).start()
    
    def cleanup():
        while True:
            now = time.time()
            with lock:
                to_del = [ip for ip, d in active_users.items() if now - d['last_seen'] > USER_TIMEOUT]
                for ip in to_del: del active_users[ip]
            time.sleep(5)
    threading.Thread(target=cleanup, daemon=True).start()
    
    main_menu()