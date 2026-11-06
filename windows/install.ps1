<#
Robotics workstation for Windows 10/11 (x64) with winget.
  powershell -ExecutionPolicy Bypass -File windows\install.ps1
  powershell -ExecutionPolicy Bypass -File windows\install.ps1 -NoRos -NoDesign -NoSim -NoEmbedded -NoEnvs -DryRun
Design apps from winget, Webots from Cyberbotics' GitHub release, ROS 2 Jazzy + Gazebo through RoboStack
(conda env "ros"; needs Visual Studio 2022 Build Tools for building your own packages), Python envs with MuJoCo,
Playground, Pinocchio and LeRobot. Crocoddyl has no Windows build: use WSL 2 + linux/install.sh for it, or for
the full apt-based ROS 2 / Gazebo experience (see README).
#>
param([switch]$NoRos, [switch]$NoDesign, [switch]$NoSim, [switch]$NoEmbedded, [switch]$NoEnvs, [switch]$DryRun)
$ErrorActionPreference = "Continue"
$Here = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Force -Path "$Here\logs" | Out-Null
$Log = "$Here\logs\windows-install-$(Get-Date -Format yyyyMMdd-HHmmss).log"
Start-Transcript -Path $Log | Out-Null
$Failed = New-Object System.Collections.Generic.List[string]
function Step($m) { Write-Host "`n[$(Get-Date -Format HH:mm:ss)] >>> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; $Failed.Add($m) }
function Run([scriptblock]$b) { if ($DryRun) { Write-Host "[dry-run] $($ExecutionContext.InvokeCommand.ExpandString($b.ToString().Trim()))" } else { & $b } }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "winget not found. Install 'App Installer' from the Microsoft Store, then re-run."; Stop-Transcript | Out-Null; exit 1
}
function Install-WingetPackage([string]$Id, [string]$Override = "") {
  $listed = winget list --id $Id -e --accept-source-agreements 2>$null | Out-String
  if ($listed -match [regex]::Escape($Id)) { Ok "$Id already installed"; return }
  if ($Override) { Run { winget install --id $Id -e --accept-package-agreements --accept-source-agreements --override $Override } }
  else { Run { winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements } }
  if (-not $DryRun -and $LASTEXITCODE -ne 0) { Fail "winget $Id (exit $LASTEXITCODE)" } elseif (-not $DryRun) { Ok $Id }
}

Step "Core tools"
foreach ($id in @("Git.Git", "GitHub.cli", "astral-sh.uv", "CondaForge.Miniforge3", "Microsoft.VisualStudioCode")) { Install-WingetPackage $id }

if (-not $NoDesign) {
  Step "Design: KiCad, FreeCAD, Blender, OrcaSlicer"
  foreach ($id in @("KiCad.KiCad", "FreeCAD.FreeCAD", "BlenderFoundation.Blender", "SoftFever.OrcaSlicer")) { Install-WingetPackage $id }
}
if (-not $NoEmbedded) { Step "Arduino IDE"; Install-WingetPackage "ArduinoSA.IDE.stable" }
if (-not $NoRos) {
  Step "Visual Studio 2022 Build Tools with C++ (RoboStack needs them to build ROS packages)"
  Install-WingetPackage "Microsoft.VisualStudio.2022.BuildTools" "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
}

if (-not $NoSim) {
  Step "Webots R2025a (official installer from github.com/cyberbotics/webots)"
  if ((Test-Path "$env:LOCALAPPDATA\Programs\Webots") -or (Test-Path "$env:ProgramFiles\Webots")) { Ok "Webots present" }
  else {
    $url = "https://github.com/cyberbotics/webots/releases/download/R2025a/webots-R2025a_setup.exe"
    $exe = "$env:TEMP\webots-R2025a_setup.exe"
    Run { Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing }
    if (-not $DryRun) {
      $sig = Get-AuthenticodeSignature $exe
      Write-Host "Installer signature: $($sig.Status) $($sig.SignerCertificate.Subject)"
      $p = Start-Process -FilePath $exe -ArgumentList "/SILENT" -Wait -PassThru
      if ($p.ExitCode -ne 0) { Fail "webots (installer exit $($p.ExitCode))" } else { Ok "Webots installed" }
    }
  }
}

$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
$Conda = $env:CONDA_ROOT
if (-not $Conda) { foreach ($c in @("$env:USERPROFILE\miniforge3", "$env:LOCALAPPDATA\miniforge3", "$env:ProgramData\miniforge3")) { if (Test-Path "$c\Scripts\conda.exe") { $Conda = $c; break } } }
if (-not $Conda -and -not $DryRun) { Fail "Miniforge not found (open a new PowerShell and re-run)"; Stop-Transcript | Out-Null; exit 1 }
$Mamba = "$Conda\Library\bin\mamba.exe"; if (-not (Test-Path $Mamba)) { $Mamba = "$Conda\Scripts\conda.exe" }
$Uv = (Get-Command uv -ErrorAction SilentlyContinue).Source; if (-not $Uv) { $Uv = "$env:USERPROFILE\.local\bin\uv.exe" }
function Has([string]$Env, [string]$Mods) { $p = "$Conda\envs\$Env\python.exe"; if (-not (Test-Path $p)) { return $false }; & $p -c "import $Mods" 2>$null; return ($LASTEXITCODE -eq 0) }
function MkEnv([string]$Env, [string[]]$Pkgs) { if (-not (Test-Path "$Conda\envs\$Env\python.exe")) { Run { & $Mamba create -y -q -n $Env @Pkgs } } }
function UvReq([string]$Env, [string[]]$Extra) {
  $py = "$Conda\envs\$Env\python.exe"
  Run { & $Uv pip install --python $py @Extra -r "$Here\requirements\$Env.txt" }
  if (-not $DryRun -and $LASTEXITCODE -ne 0) { Fail "packages in $Env" }
}

if (-not $NoEmbedded) {
  Step "PlatformIO"
  if (Get-Command pio -ErrorAction SilentlyContinue) { Ok "present" } else { Run { & $Uv tool install platformio } }
}

if (-not $NoRos) {
  Step "ROS 2 Jazzy via RoboStack (env 'ros'): desktop, Gazebo bridge, Nav2, SLAM Toolbox, MoveIt"
  if ((Test-Path "$Conda\envs\ros\Library\bin\ros2.exe") -or (Test-Path "$Conda\envs\ros\Scripts\ros2.exe")) { Ok "present" }
  else {
    MkEnv "ros" @("-c", "conda-forge", "-c", "robostack-jazzy", "ros-jazzy-desktop", "ros-jazzy-ros-gz", "ros-jazzy-navigation2",
                  "ros-jazzy-slam-toolbox", "ros-jazzy-moveit", "ros-jazzy-xacro", "ros-jazzy-teleop-twist-keyboard", "ros-dev-tools")
    Run { & "$Conda\Scripts\conda.exe" config --file "$Conda\envs\ros\.condarc" --add channels conda-forge }
    Run { & "$Conda\Scripts\conda.exe" config --file "$Conda\envs\ros\.condarc" --add channels robostack-jazzy }
  }
}

if (-not $NoEnvs) {
  Step "env sim"
  if (Has "sim" "mujoco, pybullet, gymnasium, stable_baselines3") { Ok "complete" } else { MkEnv "sim" @("-c", "conda-forge", "python=3.12", "pip"); UvReq "sim" @() }
  Step "env humanoid (Pinocchio; Crocoddyl is not built for Windows)"
  if (Has "humanoid" "mujoco_playground, pinocchio") { Ok "complete" } else { MkEnv "humanoid" @("-c", "conda-forge", "python=3.12", "pip", "pinocchio"); UvReq "humanoid" @("jax") }
  Step "env lerobot"
  if (Has "lerobot" "lerobot") { Ok "complete" }
  else {
    MkEnv "lerobot" @("-c", "conda-forge", "python=3.12", "pip", "ffmpeg")
    # PyPI's Windows torch is CPU-only: with an NVIDIA driver, take LeRobot's supported torch from the CUDA index first
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
      Run { & $Uv pip install --python "$Conda\envs\lerobot\python.exe" "torch>=2.7,<2.12" "torchvision<0.27" --index-url https://download.pytorch.org/whl/cu126 }
    }
    UvReq "lerobot" @()
  }
}

Step "Verify"
if (-not $DryRun) {
  $env:CONDA_ROOT = $Conda
  & "$Conda\python.exe" "$Here\verify\verify.py" --out "$Here\outputs\$env:COMPUTERNAME-windows.md"
  if ($LASTEXITCODE -ne 0) { Fail "verification found problems" }
}
Stop-Transcript | Out-Null
if ($Failed.Count) { Write-Host "`nFINISHED WITH PROBLEMS: $($Failed -join '; ')`nLog: $Log" -ForegroundColor Yellow; exit 1 }
Write-Host "`nALL DONE. Open 'Miniforge Prompt': conda activate ros  (ROS 2 + Gazebo), or sim / humanoid / lerobot. Log: $Log" -ForegroundColor Green
