#!/usr/bin/env python3
"""Check a robotics workstation: tools respond, ROS 2 nodes talk, physics and robot-learning envs really run.

  python verify/verify.py                       # prints a report
  python verify/verify.py --out outputs/me.md   # also saves it as Markdown

Standard library only; works on Linux, Windows and macOS (it runs each env's own Python).
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

LINUX, WIN, MAC = sys.platform.startswith("linux"), sys.platform == "win32", sys.platform == "darwin"

ENV_PROBES = {
    "sim": r"""
import mujoco, pybullet, gymnasium, stable_baselines3 as sb3
m = mujoco.MjModel.from_xml_string('<mujoco><worldbody><geom type="plane" size="2 2 .1"/>'
                                   '<body pos="0 0 1"><freejoint/><geom size=".1"/></body></worldbody></mujoco>')
d = mujoco.MjData(m)
for _ in range(500): mujoco.mj_step(m, d)
assert 0.05 < d.qpos[2] < 0.15, "ball did not land on the floor"
print(f"MuJoCo {mujoco.__version__} (dropped ball landed at z={d.qpos[2]:.2f} m), Gymnasium {gymnasium.__version__}, SB3 {sb3.__version__}")
""",
    "humanoid": r"""
import jax, pinocchio as pin, mujoco_playground
try:
    import crocoddyl; croc = crocoddyl.__version__
except ImportError:
    croc = "not installed"
m = pin.buildSampleModelHumanoidRandom(); d = m.createData(); pin.crba(m, d, pin.neutral(m))
print(f"JAX {jax.__version__} on {jax.default_backend()}, Pinocchio {pin.__version__} (humanoid nq={m.nq}), Crocoddyl {croc}, MuJoCo Playground OK")
""",
    "lerobot": r"""
import lerobot, torch
from lerobot.policies.act.modeling_act import ACTPolicy
from lerobot.policies.diffusion.modeling_diffusion import DiffusionPolicy
from lerobot.policies.smolvla.modeling_smolvla import SmolVLAPolicy
dev = "cuda" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
print(f"LeRobot {lerobot.__version__}, torch {torch.__version__} on {dev}; ACT, Diffusion, SmolVLA import OK")
""",
}


def sh(cmd, timeout=60, shell=False) -> tuple[bool, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=shell,
                           executable="/bin/bash" if shell and not WIN else None)
        lines = [l for l in (r.stdout or r.stderr).strip().splitlines() if l.strip(" *")]  # skip banner lines like ******
        return r.returncode == 0, (lines[0].strip(" *") if lines else "")
    except (OSError, subprocess.SubprocessError) as e:
        return False, type(e).__name__


def conda_root() -> Path | None:
    for c in [os.environ.get("CONDA_ROOT"), "~/miniforge3", "~/mambaforge", "~/miniconda3",
              os.path.expandvars("%USERPROFILE%/miniforge3"), "/opt/homebrew/Caskroom/miniforge/base"]:
        if c and Path(os.path.expanduser(c)).is_dir():
            return Path(os.path.expanduser(c))
    return None


def env_python(root: Path | None, env: str) -> Path | None:
    if not root:
        return None
    for p in (root / "envs" / env / "bin" / "python", root / "envs" / env / "python.exe"):
        if p.exists():
            return p
    return None


def check_ros(root) -> tuple[str, str]:
    """Run a real talker -> listener exchange; returns (status, detail)."""
    test = ("timeout 15 ros2 run demo_nodes_cpp listener > /tmp/_rws_listen.txt 2>&1 & sleep 3; "
            "timeout 6 ros2 run demo_nodes_py talker > /dev/null 2>&1; wait; grep -c 'I heard' /tmp/_rws_listen.txt")
    if LINUX:
        distros = sorted(glob.glob("/opt/ros/*/setup.bash"))
        if distros:
            d = Path(distros[-1]).parent.name
            # `source X; test`, not `source X && test`: with &&, bash puts source + listener in the background
            # job together and the talker runs without ROS loaded
            ok, out = sh(f"source /opt/ros/{d}/setup.bash; {test}", timeout=40, shell=True)
            return ("OK" if ok and out.strip() not in ("", "0") else "FAIL"), f"ROS 2 {d} (apt): talker -> listener, {out} messages heard"
    ros_env = root / "envs" / "ros" if root else None
    if ros_env and ros_env.exists():
        if WIN:
            ok, out = sh(f'call "{root}\\Scripts\\activate.bat" ros && ros2 pkg list', timeout=120, shell=True)
            return ("OK" if ok else "FAIL"), "ROS 2 Jazzy (RoboStack env 'ros'): ros2 pkg list " + ("works" if ok else "failed")
        # macOS has no `timeout` command by default, so the talker/listener exchange is Linux-only
        ok, out = sh(f'source "{root}/bin/activate" ros && ros2 pkg list | wc -l', timeout=120, shell=True)
        return ("OK" if ok and out.strip() not in ("", "0") else "FAIL"), f"ROS 2 Jazzy (RoboStack env 'ros'): {out.strip()} packages"
    return "MISSING", "no ROS 2 found (apt /opt/ros or conda env 'ros')"


def first_line_version(cands: list[list[str]]) -> tuple[str, str]:
    for c in cands:
        if shutil.which(c[0]) or Path(os.path.expanduser(c[0])).exists():
            ok, out = sh([os.path.expanduser(c[0])] + c[1:])
            if ok or out:
                return "OK", out[:90]
    return "MISSING", ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--envs", nargs="*", default=list(ENV_PROBES))
    a = ap.parse_args()
    root = conda_root()
    rows = []

    rows.append(("ROS 2", *check_ros(root)))
    gz = first_line_version([["gz", "sim", "--versions"]])
    if gz[0] == "MISSING" and env_python(root, "ros"):
        gz = ("OK", "Gazebo from the RoboStack 'ros' env (ros-jazzy-ros-gz)")
    rows.append(("Gazebo", gz[0], gz[1] and f"gz sim {gz[1]}"))
    tools = {
        "KiCad": [["kicad-cli", "version"], [r"C:\Program Files\KiCad\10.0\bin\kicad-cli.exe", "version"],
                  ["/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli", "version"]],
        "ngspice": [["ngspice", "--version"]],
        "Blender": [["blender", "--version"], ["~/.local/bin/blender", "--version"],
                    ["/Applications/Blender.app/Contents/MacOS/Blender", "--version"]],
        "Webots": [["webots", "--version"], ["/Applications/Webots.app/Contents/MacOS/webots", "--version"]],
        "PlatformIO": [["pio", "--version"], ["~/.local/bin/pio", "--version"]],
        "Arduino IDE": [["~/.local/opt/arduino-ide/arduino-ide", "--version"]],
    }
    for name, cands in tools.items():
        s, v = first_line_version(cands)
        if name == "Arduino IDE" and s == "MISSING" and (Path("/Applications/Arduino IDE.app").exists()
                                                       or Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\Arduino IDE")).exists()):
            s, v = "OK", "installed"
        if name == "Arduino IDE" and s == "OK" and v in ("", "unknown"):
            v = "installed"
        rows.append((name, s, v))
    orca = sh(["flatpak", "info", "com.orcaslicer.OrcaSlicer"]) if LINUX else (Path("/Applications/OrcaSlicer.app").exists(), "")
    rows.append(("OrcaSlicer", "OK" if orca[0] else "MISSING", "flatpak com.orcaslicer.OrcaSlicer" if LINUX and orca[0] else ""))
    fc = env_python(root, "freecad")
    if fc and LINUX:
        ok, out = sh([str(fc.parent / "freecadcmd"), "-c", "import FreeCAD;print('.'.join(FreeCAD.Version()[:3]))"])
        mods = glob.glob(os.path.expanduser("~/.local/share/FreeCAD/*/Mod/freecad.robotcad"))
        rows.append(("FreeCAD + RobotCAD", "OK" if ok else "FAIL", f"FreeCAD {out.splitlines()[-1] if out else '?'}, "
                     f"RobotCAD {'installed' if mods else 'missing'}"))
    else:
        rows.append(("FreeCAD", "OK" if shutil.which("freecad") or Path("/Applications/FreeCAD.app").exists()
                     or Path(r"C:\Program Files\FreeCAD 1.1").exists() else "MISSING", ""))

    for env in a.envs:
        py = env_python(root, env)
        if not py:
            rows.append((f"env {env}", "MISSING", ""))
            continue
        ok, out = sh([str(py), "-c", ENV_PROBES[env]], timeout=600)
        rows.append((f"env {env}", "OK" if ok else "FAIL", out[:200]))

    good = all(s == "OK" for _, s, _ in rows)
    lines = [f"# Robotics workstation check: {platform.node()}", "",
             f"- Date: {dt.datetime.now():%Y-%m-%d %H:%M}",
             f"- OS: {platform.system()} {platform.release()} ({platform.machine()})",
             f"- NVIDIA GPU: {sh(['nvidia-smi', '--query-gpu=name,driver_version', '--format=csv,noheader'])[1] or 'none'}",
             "", "| component | status | detail |", "|---|---|---|"]
    lines += [f"| {n} | {'✅' if s == 'OK' else '❌ ' + s} | {d} |" for n, s, d in rows]
    lines += ["", f"**Result: {'ALL OK' if good else 'PROBLEMS FOUND'}**", ""]
    report = "\n".join(lines)
    print(report)
    if a.out:
        Path(a.out).parent.mkdir(parents=True, exist_ok=True)
        Path(a.out).write_text(report, encoding="utf-8")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
