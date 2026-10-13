#!/bin/bash
#
# Start the dashboard server (unless it is already running), then a stream
# run that feeds it; open http://<this host>:8080/ to watch. Ctrl-C stops
# the run (the server keeps running; stop it with: pkill -f dashboard/server).
#
# usage: start.sh [radar-bench stream options]
#   default: 375 MS/s, targets moving at 60 range bins/s, for ~45 minutes
#
# Needs the picoevb-rdma driver loaded and the FPGA's generator design.

set -e
cd "$(dirname "${0}")/.."

if ! pgrep -f "python3 dashboard/server.py" > /dev/null; then
	nohup python3 dashboard/server.py < /dev/null > /tmp/radar-dashboard.log 2>&1 &
	sleep 1
fi
echo "dashboard: http://$(hostname -I | awk '{print $1}'):8080/"

args=("$@")
if [ ${#args[@]} -eq 0 ]; then
	args=(--rate-msps 375 --move 60 --cpis 2000000)
fi
exec sudo ./radar-bench stream --N 4096 --M 128 --L 512 \
	--telemetry 127.0.0.1:7700 "${args[@]}"
