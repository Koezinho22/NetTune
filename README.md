
# Network Optimizer

network optimizer is a optimizer that optimizes your networks settings and currently in beta testing, you can run it through command prompt




## Installation

### Requirements
- **Windows 7 or later**
- **Administrator privileges** (required)
- **PowerShell 3.0+** (built-in on Windows)

### Steps

1. **Download the script**
   - Download `NetTune.ps1` to your `Downloads` folder (or any location you prefer)

2. **Open PowerShell as Administrator**
   - Press `Win + X` → Select **Windows PowerShell (Admin)**
   - OR right-click PowerShell → **Run as administrator**

3. **Navigate to the download location**
   ```powershell
   cd Downloads
   # Or if downloaded elsewhere:
   # cd "C:\path\to\folder"
Allow script execution (one-time setup)

PowerShell

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Run the script

PowerShell

.\NetTune.ps1

            
Troubleshooting

"cannot be loaded because running scripts is disabled"
Make sure you ran PowerShell as Administrator
Re-run the Set-ExecutionPolicy command above

"The term 'NetTune.ps1' is not recognized"
Verify you're in the correct directory: pwd
Make sure the filename matches exactly (case-sensitive on some systems)

Script won't run/freezes
Restart PowerShell as Administrator
Try running: powershell -ExecutionPolicy Bypass -File .\NetTune.ps1
What does this script do?
NetTune optimizes Roblox network settings for better performance and lower latency.