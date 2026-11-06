#!/usr/bin/env bash
# Robotics workstation for macOS 14+ (Apple Silicon recommended), with Homebrew.
#   ./macos/install.sh                      everything
#   ./macos/install.sh --no-design --no-ros --no-sim --no-embedded --no-envs --dry-run
# ROS 2 Jazzy + Gazebo + Nav2 + SLAM Toolbox + MoveIt through RoboStack (conda env "ros"), design apps through
# Homebrew casks, Python envs with MuJoCo, Playground, Pinocchio, Crocoddyl and LeRobot.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROS=1; DESIGN=1; SIM=1; EMBEDDED=1; ENVS=1; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --no-ros) ROS=0 ;; --no-design) DESIGN=0 ;; --no-sim) SIM=0 ;; --no-embedded) EMBEDDED=0 ;; --no-envs) ENVS=0 ;;
  --dry-run) DRY=1 ;; -h|--help) sed -n '2,6p' "$0"; exit 0 ;; *) echo "unknown option $1"; exit 2 ;;
esac; shift; done

LOG="$HERE/logs/macos-install-$(date +%Y%m%d-%H%M%S).log"; mkdir -p "$HERE/logs"
exec > >(tee -a "$LOG") 2>&1
FAILED=()
log()  { echo; echo "[$(date +%H:%M:%S)] >>> $*"; }
ok()   { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; FAILED+=("$*"); }
run()  { if ((DRY)); then echo "[dry-run] $*"; else "$@"; fi; }
retry() { local n=1; until "$@"; do ((n >= 3)) && return 1; echo "retry $n: $*"; n=$((n + 1)); sleep 5; done; }

[ "$(uname)" = Darwin ] || { echo "macOS only"; exit 1; }
ARCH=$(uname -m)
echo "Robotics setup on macOS $(sw_vers -productVersion) ($ARCH), log: $LOG"
[ "$ARCH" = arm64 ] || echo "Note: Intel Macs are not supported by current MuJoCo wheels; the sim/humanoid envs may fail."

command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh (review the script first), then re-run."; exit 1; }
binst() { local kind=$1; shift; for p in "$@"; do
  if brew list $kind "$p" >/dev/null 2>&1; then ok "$p"; else run retry brew install $kind "$p" || fail "brew $p"; fi; done; }

log "Command-line tools + Miniforge"
binst --formula git gh uv cmake
binst --cask miniforge
CONDA=${CONDA_ROOT:-$(brew --prefix)/Caskroom/miniforge/base}
[ -x "$CONDA/bin/conda" ] || CONDA=$HOME/miniforge3
[ -x "$CONDA/bin/conda" ] || ((DRY)) || { fail "conda not found"; exit 1; }
((DRY)) || "$CONDA/bin/conda" init zsh bash >/dev/null 2>&1
mkenv() { [ -x "$CONDA/envs/$1/bin/python" ] || run "$CONDA/bin/mamba" create -y -q -n "$1" "${@:2}"; }
has() { "$CONDA/envs/$1/bin/python" -c "import $2" >/dev/null 2>&1; }

if ((DESIGN)); then log "Design: KiCad, FreeCAD, Blender, OrcaSlicer"; binst --cask kicad freecad blender orcaslicer; fi
if ((SIM)); then log "Webots"; binst --cask webots; fi
if ((EMBEDDED)); then log "Arduino IDE + PlatformIO"; binst --cask arduino-ide; binst --formula platformio; fi

if ((ROS)); then
  log "ROS 2 Jazzy via RoboStack (env 'ros'): desktop, Gazebo bridge, Nav2, SLAM Toolbox, MoveIt"
  if [ -x "$CONDA/envs/ros/bin/ros2" ]; then ok "present"
  else
    mkenv ros -c conda-forge -c robostack-jazzy ros-jazzy-desktop ros-jazzy-ros-gz ros-jazzy-navigation2 \
      ros-jazzy-slam-toolbox ros-jazzy-moveit ros-jazzy-xacro ros-jazzy-teleop-twist-keyboard ros-dev-tools \
      || fail "ROS 2 (RoboStack)"
    # keep the robostack channel for later installs into this env
    run "$CONDA/bin/conda" config --file "$CONDA/envs/ros/.condarc" --add channels conda-forge
    run "$CONDA/bin/conda" config --file "$CONDA/envs/ros/.condarc" --add channels robostack-jazzy
  fi
fi

if ((ENVS)); then
  log "env sim"
  if has sim "mujoco, pybullet, gymnasium, stable_baselines3"; then ok "complete"
  else mkenv sim -c conda-forge python=3.12 pip && run retry uv pip install --python "$CONDA/envs/sim/bin/python" -r "$HERE/requirements/sim.txt" || fail "env sim"; fi
  log "env humanoid (JAX runs on the CPU on macOS: fine for testing, train big policies on a CUDA machine)"
  if has humanoid "mujoco_playground, pinocchio, crocoddyl"; then ok "complete"
  else mkenv humanoid -c conda-forge python=3.12 pip pinocchio crocoddyl \
    && run retry uv pip install --python "$CONDA/envs/humanoid/bin/python" jax -r "$HERE/requirements/humanoid.txt" || fail "env humanoid"; fi
  log "env lerobot"
  if has lerobot "lerobot"; then ok "complete"
  else mkenv lerobot -c conda-forge python=3.12 pip ffmpeg && run retry uv pip install --python "$CONDA/envs/lerobot/bin/python" -r "$HERE/requirements/lerobot.txt" || fail "env lerobot"; fi
fi

log "Verify"
((DRY)) || CONDA_ROOT="$CONDA" python3 "$HERE/verify/verify.py" --out "$HERE/outputs/$(hostname -s)-macos.md" || fail "verification found problems"
echo
if ((${#FAILED[@]})); then echo "FINISHED WITH PROBLEMS: ${FAILED[*]}"; echo "Log: $LOG"; exit 1; fi
echo "ALL DONE. New terminal, then: conda activate ros  (ROS 2 + Gazebo), or conda activate sim / humanoid / lerobot. Log: $LOG"
