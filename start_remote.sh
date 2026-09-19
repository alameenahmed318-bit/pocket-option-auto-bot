#!/bin/sh
set -eu

: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"
: "${PORT:?Railway PORT is required}"

export DISPLAY=:99
Xvfb :99 -screen 0 392x844x24 -ac +extension GLX +extension RANDR &
sleep 3
x11vnc -display :99 -forever -shared -rfbport 5901 -nopw -localhost -noshm -noxdamage -noxfixes -noxrecord -wait 10 -defer 10 -ncache 0 &
sleep 2

TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s: localhost:5901\n' "$TOKEN" > /tmp/websockify.tokens

cat > /usr/share/novnc/index.html <<EOF
<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta http-equiv="refresh" content="0;url=/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}">
<script>location.replace("/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}");</script>
</head><body></body></html>
EOF

websockify --web=/usr/share/novnc/ --file-only   --token-plugin websockify.token_plugins.TokenFile   --token-source /tmp/websockify.tokens   "0.0.0.0:${PORT}" &

exec python -u remote_login.py
