#!/bin/zsh
# Samples what Sunlight costs while it runs: CPU of Sunlight, WindowServer and replayd (ScreenCaptureKit's
# capture daemon) averaged over a window of seconds, and Sunlight's memory footprint with the IOSurface /
# graphics lines pulled out. Run it with Sunlight up, in the state you want to measure (idle on the canvas,
# inside an entered window, screen locked), and compare before/after a change.
#
#   scripts/perf-snapshot.sh [seconds]     default 15
set -u
seconds=${1:-15}
pid=$(pgrep -x Sunlight | head -1)
if [[ -z $pid ]]; then echo "Sunlight is not running"; exit 1; fi
ws=$(pgrep -x WindowServer | head -1)
rp=$(pgrep -x replayd | head -1)
echo "Sunlight pid $pid · WindowServer ${ws:-?} · replayd ${rp:-none} · sampling ${seconds}s"

# top -l N takes N samples a second apart; the first is a warm-up with no CPU delta, so ask for one more.
pids=(-pid "$pid")
[[ -n $ws ]] && pids+=(-pid "$ws")
[[ -n $rp ]] && pids+=(-pid "$rp")
top -l $((seconds + 1)) -s 1 -stats pid,cpu,mem,command "${pids[@]}" 2>/dev/null \
  | awk -v canvas="$pid" -v ws="${ws:-x}" -v rp="${rp:-x}" '
      /^PID/ { sample++; next }
      sample > 1 && $1 == canvas { c += $2; cn++ ; mem = $3 }
      sample > 1 && $1 == ws     { w += $2; wn++ }
      sample > 1 && $1 == rp     { r += $2; rn++ }
      END {
        printf "CPU avg  Sunlight %5.1f%%   WindowServer %5.1f%%   replayd %5.1f%%   (Sunlight mem %s)\n",
          cn ? c/cn : 0, wn ? w/wn : 0, rn ? r/rn : 0, mem
      }'

# footprint needs no root for your own processes. The IOSurface and IOAccelerator rows are the capture
# textures; CoreAnimation and CG Image are the layer tree and one-shot frames.
if command -v footprint >/dev/null; then
  footprint -p "$pid" 2>/dev/null | awk '
    /Footprint:/ { print "  " $0; next }
    /IOSurface|IOAccelerator|CoreAnimation|CG Image/ { print "  " $0 }'
fi
