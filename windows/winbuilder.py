import os
import subprocess
import sys

MAIN_SCRIPT = "main.py" 
EXE_NAME = "Conduit-Manager-Windows"

def build():
    print("--- Starting Ultimate Build Process ---")
    
    print("[1/3] Updating build tools...")
    subprocess.run([sys.executable, "-m", "pip", "install", "--upgrade", "pyinstaller", "requests", "rich", "psutil", "geoip2"])

    cmd = [
        "pyinstaller",
        "--noconfirm",
        "--onefile",
        "--console",
        "--name", EXE_NAME,
        "--clean",
        "--collect-all", "rich",
        "--hidden-import", "rich.logging",
        "--hidden-import", "rich._unicode_data",
        MAIN_SCRIPT
    ]

    print(f"[2/3] Running PyInstaller (Collecting all rich modules)...")
    result = subprocess.run(cmd)

    if result.returncode == 0:
        print(f"\n[3/3] Success! Final EXE is ready in 'dist' folder.")
    else:
        print("\n[!] Build failed. Please check logs.")

if __name__ == "__main__":
    build()