#!/bin/bash
set -e

if [ $# -gt 0 ]; then
    exec "$@"
fi

Xvfb :99 -screen 0 1280x720x24 &
sleep 1

x11vnc -display :99 -forever -nopw -quiet &
sleep 1

/opt/noVNC/utils/novnc_proxy --vnc localhost:5900 --listen 8080 &
sleep 1

export DISPLAY=:99
exec java -jar /app/parallel-malware-scanner.jar
