#!/bin/sh
set -eu

: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"

export DISPLAY=:99
Xvfb :99 -screen 0 392x844x24 -ac +extension GLX +extension RANDR &
sleep 3

x11vnc -display :99 -forever -shared -rfbport 5901 -nopw -localhost -noshm -noxdamage -noxfixes -noxrecord -wait 10 -defer 10 -ncache 0 &

sleep 2

TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s: localhost:5901\n' "$TOKEN" > /tmp/websockify.tokens

# Make the public root open noVNC directly. No intermediate login/landing page.
# The token is injected into the direct noVNC URL at container startup.
cat > /usr/share/novnc/index.html <<EOF
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta name="theme-color" content="#111">
<meta http-equiv="refresh" content="0;url=/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}">
<script>
location.replace("/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}");
</script>
</head>
<body></body>
</html>
EOF

websockify \
  --web=/usr/share/novnc/ \
  --file-only \
  --token-plugin websockify.token_plugins.TokenFile \
  --token-source /tmp/websockify.tokens \
  "${PORT}" &

PORT=8090 python -u remote_login.py &
exec python -u demo_connection_test.py
