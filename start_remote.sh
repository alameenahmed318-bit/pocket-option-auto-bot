#!/bin/sh
set -eu
: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"
export DISPLAY=:99
Xvfb :99 -screen 0 1400x900x24 -ac &
sleep 2
x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -localhost &
websockify --web=/usr/share/novnc/ --web-auth --auth-plugin websockify.auth_plugins.BasicHTTPAuth --auth-source "admin:${REMOTE_LOGIN_PASSWORD}" 6080 localhost:5900 &
python -u remote_login.py &
exec python -u demo_connection_test.py
