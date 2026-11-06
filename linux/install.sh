#!/usr/bin/env bash
# Robotics workstation for Ubuntu 22.04 (ROS 2 Humble) / 24.04 (ROS 2 Jazzy), x86_64.
#   ./linux/install.sh                      everything
#   ./linux/install.sh --no-design          skip KiCad / FreeCAD / Blender / OrcaSlicer
#   ./linux/install.sh --no-ros --no-sim --no-embedded --no-envs --humanoids --dry-run
# ROS 2 + Gazebo Harmonic from the official apt repos, design tools from their vendors, Python envs with
# MuJoCo, MuJoCo Playground, Pinocchio, Crocoddyl and LeRobot. Safe to run again (installed parts are skipped).
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ROS=1; DESIGN=1; SIM=1; EMBEDDED=1; ENVS=1; HUMANOIDS=0; DRY=0
while [ $# -gt 0 ]; do case "$1" in
  --no-ros) ROS=0 ;; --no-design) DESIGN=0 ;; --no-sim) SIM=0 ;; --no-embedded) EMBEDDED=0 ;; --no-envs) ENVS=0 ;;
  --humanoids) HUMANOIDS=1 ;; --dry-run) DRY=1 ;; -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "unknown option $1"; exit 2 ;;
esac; shift; done

MINIFORGE_VER=26.9.4-1
BLENDER=5.2.3; ARDUINO_VER=2.3.10; WEBOTS=R2025a; ORCA=v2.4.2
CONDA=${CONDA_ROOT:-$HOME/miniforge3}
OPT=$HOME/.local/opt; mkdir -p "$OPT" "$HOME/.local/bin"
LOG="$HERE/logs/linux-install-$(date +%Y%m%d-%H%M%S).log"; mkdir -p "$HERE/logs"
exec > >(tee -a "$LOG") 2>&1
FAILED=()
log()  { echo -e "\n[$(date +%H:%M:%S)] >>> $*"; }
ok()   { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; FAILED+=("$*"); }
run()  { if ((DRY)); then echo "[dry-run] $*"; else "$@"; fi; }
retry() { local n=1; until "$@"; do ((n >= 3)) && return 1; echo "retry $n: $*"; n=$((n + 1)); sleep 5; done; }
have_pkg() { dpkg -s "$1" >/dev/null 2>&1; }
apt_get() { local miss=(); for p in "$@"; do have_pkg "$p" || miss+=("$p"); done
  ((${#miss[@]})) || { ok "$* already installed" | cut -c1-120; return 0; }
  run sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${miss[@]}"; }
sha_ok() { echo "$1  $2" | sha256sum -c --status -; }

. /etc/os-release
case "$VERSION_ID" in 22.04) DISTRO=humble ;; 24.04) DISTRO=jazzy ;; *) echo "Ubuntu 22.04 or 24.04 required"; exit 1 ;; esac
[ "$(uname -m)" = x86_64 ] || { echo "x86_64 only"; exit 1; }
echo "Robotics setup on $PRETTY_NAME (ROS 2 $DISTRO), log: $LOG"

log "Base packages"
apt_get build-essential git curl wget ca-certificates gnupg cmake ninja-build unzip zstd jq python3-pip flatpak || fail "base"

# ------------------------------------------------------------------ ROS 2 + Gazebo Harmonic
if ((ROS)); then
  log "ROS 2 apt source (ros2-apt-source, per docs.ros.org)"
  if have_pkg ros2-apt-source; then ok "present"
  else
    T=$(mktemp -d); V=$(curl -fsS https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | jq -r .tag_name)
    run retry curl -fsSL -o "$T/ros2-apt-source.deb" \
      "https://github.com/ros-infrastructure/ros-apt-source/releases/download/$V/ros2-apt-source_$V.${VERSION_CODENAME}_all.deb" \
      && run sudo dpkg -i "$T/ros2-apt-source.deb" || fail "ros2-apt-source"
    rm -rf "$T"
  fi
  log "Gazebo apt source (packages.osrfoundation.org)"
  if [ -s /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg ]; then ok "present"
  else
    run sudo curl -fsSL https://packages.osrfoundation.org/gazebo.gpg -o /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] http://packages.osrfoundation.org/gazebo/ubuntu-stable $VERSION_CODENAME main" \
      | run sudo tee /etc/apt/sources.list.d/gazebo-stable.list >/dev/null
  fi
  have_pkg ros-$DISTRO-desktop || run sudo apt-get update

  log "ROS 2 $DISTRO desktop + dev tools"
  apt_get ros-$DISTRO-desktop ros-dev-tools python3-rosdep python3-colcon-common-extensions || fail "ROS 2 core"
  log "Gazebo Harmonic + ROS bridge"
  if [ "$DISTRO" = humble ]; then apt_get gz-harmonic ros-humble-ros-gzharmonic || fail "gazebo"
  else apt_get ros-jazzy-ros-gz || fail "gazebo"; fi   # Jazzy's default Gazebo is Harmonic
  log "Navigation, manipulation, mapping, control"
  for p in navigation2 nav2-bringup slam-toolbox moveit ros2-control ros2-controllers robot-localization xacro \
           joint-state-publisher-gui teleop-twist-keyboard plotjuggler-ros nav2-map-server; do
    apt_get ros-$DISTRO-$p || fail "ros-$DISTRO-$p"
  done
  [ -f /etc/ros/rosdep/sources.list.d/20-default.list ] || run sudo rosdep init || fail "rosdep init"
  run rosdep update --rosdistro $DISTRO >/dev/null || fail "rosdep update"
  grep -q "ros2env()" ~/.bashrc 2>/dev/null || ((DRY)) || cat >> ~/.bashrc <<EOF

# ROS 2 on demand (added by robotics-workstation-setup): type ros2env
ros2env() { source /opt/ros/$DISTRO/setup.bash; [ -f ~/ros2_ws/install/setup.bash ] && source ~/ros2_ws/install/setup.bash; export GZ_IP=127.0.0.1; echo "ROS 2 \$ROS_DISTRO ready"; }
EOF
fi

# ------------------------------------------------------------------ design: electronics, CAD, 3-D print, render
if ((DESIGN)); then
  log "KiCad 10 + ngspice (official KiCad PPA)"
  if have_pkg kicad; then ok "kicad $(dpkg-query -W -f='${Version}' kicad)"
  else
    run sudo add-apt-repository -y ppa:kicad/kicad-10.0-releases && run sudo apt-get update \
      && apt_get kicad kicad-symbols kicad-footprints kicad-templates || fail "kicad"
  fi
  apt_get ngspice || fail "ngspice"

  log "Blender $BLENDER (official tarball, sha256-checked)"
  BL=blender-$BLENDER-linux-x64
  if [ -x "$OPT/$BL/blender" ]; then ok "present"
  else
    T=$(mktemp -d); base=https://download.blender.org/release/Blender${BLENDER%.*}
    if run retry curl -fL -o "$T/$BL.tar.xz" "$base/$BL.tar.xz" && run curl -fsSL -o "$T/sums" "$base/blender-$BLENDER.sha256"; then
      ((DRY)) || { sha_ok "$(grep " $BL.tar.xz$" "$T/sums" | cut -d' ' -f1)" "$T/$BL.tar.xz" && tar -xf "$T/$BL.tar.xz" -C "$OPT" || fail "blender checksum"; }
    else fail "blender download"; fi
    rm -rf "$T"
  fi
  ((DRY)) || ln -sfn "$OPT/$BL/blender" "$HOME/.local/bin/blender"

  log "OrcaSlicer $ORCA (official flatpak bundle, sha256-checked)"
  if flatpak list --app --columns=application 2>/dev/null | grep -qi orcaslicer; then ok "present"
  else
    meta=$(curl -fsS "https://api.github.com/repos/SoftFever/OrcaSlicer/releases/tags/$ORCA" | jq -r '.assets[]|select(.name|test("Linux-flatpak.*x86_64"))|.browser_download_url+" "+.digest' | head -1)
    read -r url digest <<<"$meta"; T=$(mktemp -d)
    run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    if run retry curl -fL -o "$T/orca.flatpak" "$url" && { ((DRY)) || sha_ok "${digest#sha256:}" "$T/orca.flatpak"; }; then
      run flatpak install --user --noninteractive -y "$T/orca.flatpak" || fail "orcaslicer"
    else fail "orcaslicer download/checksum"; fi
    rm -rf "$T"
  fi
fi

# ------------------------------------------------------------------ Webots
if ((SIM)); then
  log "Webots $WEBOTS (official .deb from Cyberbotics)"
  if have_pkg webots; then ok "present"
  else
    T=$(mktemp -d); f=webots_${WEBOTS#R}_amd64.deb; f=${f,,}
    run retry curl -fL -o "$T/$f" "https://github.com/cyberbotics/webots/releases/download/$WEBOTS/$f" \
      && run sudo apt-get install -y "$T/$f" || fail "webots"
    rm -rf "$T"
  fi
fi

# ------------------------------------------------------------------ embedded
if ((EMBEDDED)); then
  log "Arduino IDE $ARDUINO_VER, PlatformIO, serial access"
  if [ -x "$OPT/arduino-ide/arduino-ide" ]; then ok "Arduino IDE present"
  else
    T=$(mktemp -d)
    run retry curl -fsSL -o "$T/a.zip" "https://downloads.arduino.cc/arduino-ide/arduino-ide_${ARDUINO_VER}_Linux_64bit.zip" \
      && run unzip -q "$T/a.zip" -d "$T/x" && run mv "$T"/x/arduino-ide_* "$OPT/arduino-ide" || fail "arduino ide"
    rm -rf "$T"
    [ -f "$OPT/arduino-ide/chrome-sandbox" ] && run sudo chown root:root "$OPT/arduino-ide/chrome-sandbox" && run sudo chmod 4755 "$OPT/arduino-ide/chrome-sandbox"
  fi
  command -v uv >/dev/null || [ -x "$CONDA/bin/uv" ] || run python3 -m pip install --user uv
  UV=$(command -v uv || echo "$CONDA/bin/uv")
  command -v pio >/dev/null && ok "$(pio --version)" || run "$UV" tool install platformio || fail "platformio"
  id -nG | grep -qw dialout || run sudo usermod -aG dialout "$USER"
fi

# ------------------------------------------------------------------ Python envs
if ((ENVS)); then
  log "Miniforge $MINIFORGE_VER (sha256-verified)"
  if [ -x "$CONDA/bin/conda" ]; then ok "found at $CONDA"
  else
    T=$(mktemp -d); base=https://github.com/conda-forge/miniforge/releases/download/$MINIFORGE_VER/Miniforge3-$MINIFORGE_VER-Linux-x86_64.sh
    run retry curl -fsSL -o "$T/mf.sh" "$base" && run curl -fsSL -o "$T/mf.sha256" "$base.sha256" \
      && { ((DRY)) || (cd "$T" && echo "$(awk '{print $1}' mf.sha256)  mf.sh" | sha256sum -c -); } \
      && run bash "$T/mf.sh" -b -p "$CONDA" && run "$CONDA/bin/conda" init bash >/dev/null || { fail "Miniforge"; }
    rm -rf "$T"
  fi
  [ -x "$CONDA/bin/uv" ] || command -v uv >/dev/null || run "$CONDA/bin/mamba" install -y -n base -c conda-forge uv
  UV=$(command -v uv || echo "$CONDA/bin/uv")
  GPU=0; nvidia-smi >/dev/null 2>&1 && GPU=1
  mkenv() { [ -x "$CONDA/envs/$1/bin/python" ] || run "$CONDA/bin/mamba" create -y -q -n "$1" -c conda-forge python=3.12 pip "${@:2}"; }
  has() { "$CONDA/envs/$1/bin/python" -c "import $2" >/dev/null 2>&1; }

  log "env sim: MuJoCo, PyBullet, Gymnasium, Stable-Baselines3, Open3D"
  if has sim "mujoco, pybullet, gymnasium, stable_baselines3"; then ok "complete"
  else mkenv sim && run retry "$UV" pip install --python "$CONDA/envs/sim/bin/python" -r "$HERE/requirements/sim.txt" || fail "env sim"; fi

  log "env humanoid: MuJoCo Playground (JAX), Pinocchio, Crocoddyl, onshape-to-robot"
  if has humanoid "mujoco_playground, pinocchio, crocoddyl, onshape_to_robot"; then ok "complete"
  else
    JAX=jax; ((GPU)) && JAX="jax[cuda12]"
    mkenv humanoid pinocchio crocoddyl && run retry "$UV" pip install --python "$CONDA/envs/humanoid/bin/python" "$JAX" \
      -r "$HERE/requirements/humanoid.txt" || fail "env humanoid"
  fi

  log "env lerobot: LeRobot (ACT, Diffusion, SmolVLA) + faster-whisper"
  if has lerobot "lerobot, faster_whisper"; then ok "complete"
  else mkenv lerobot ffmpeg && run retry "$UV" pip install --python "$CONDA/envs/lerobot/bin/python" -r "$HERE/requirements/lerobot.txt" || fail "env lerobot"; fi

  if ((DESIGN)); then
    log "env freecad: FreeCAD (conda-forge) + RobotCAD workbench (CAD -> URDF / ROS 2)"
    if [ -x "$CONDA/envs/freecad/bin/freecad" ]; then ok "FreeCAD present"
    else mkenv freecad "freecad>=1.1" numpy pandas matplotlib requests pycollada defusedxml || fail "freecad"; fi
    if [ -x "$CONDA/envs/freecad/bin/freecadcmd" ] && ! ((DRY)); then
      run "$UV" pip install --python "$CONDA/envs/freecad/bin/python" urdf-parser-py xacro xacrodoc mujoco ros-ament-index-python xmltodict lxml >/dev/null || fail "robotcad deps"
      mod=$("$CONDA/envs/freecad/bin/freecadcmd" -c 'import FreeCAD;print(FreeCAD.getUserAppDataDir())' 2>/dev/null | tail -1)Mod
      mkdir -p "$mod"; [ -d "$mod/freecad.robotcad/.git" ] || git clone -q --depth 1 https://github.com/drfenixion/freecad.robotcad.git "$mod/freecad.robotcad" || fail "robotcad"
    fi
  fi
fi

# ------------------------------------------------------------------ reference humanoids (optional, ~4.5 GB)
if ((HUMANOIDS)); then
  log "Reference humanoid projects -> ~/robotics/humanoids"
  H=$HOME/robotics/humanoids; mkdir -p "$H"
  for r in HybridRobotics/Berkeley-Humanoid-Lite HybridRobotics/Berkeley-Humanoid-Lite-Assets hshi74/toddlerbot \
           unitreerobotics/unitree_mujoco google-deepmind/mujoco_menagerie; do
    d="$H/$(basename "$r" | tr 'A-Z' 'a-z')"
    [ -d "$d/.git" ] && ok "$r" || run retry git clone -q --depth 1 "https://github.com/$r.git" "$d" || fail "$r"
  done
fi

log "Verify"
((DRY)) || python3 "$HERE/verify/verify.py" --out "$HERE/outputs/$(hostname)-linux.md" || fail "verification found problems"
echo
if ((${#FAILED[@]})); then echo "FINISHED WITH PROBLEMS: ${FAILED[*]}"; echo "Log: $LOG"; exit 1; fi
echo "ALL DONE. New terminal, then: ros2env   (ROS 2 + Gazebo), or conda activate sim / humanoid / lerobot. Log: $LOG"
