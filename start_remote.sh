#!/bin/sh
set -eu

: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"

export DISPLAY=:99
Xvfb :99 -screen 0 390x844x24 -ac +extension GLX +extension RANDR &
sleep 3

# Share the X display. -noshm avoids shared-memory issues that can produce a black VNC canvas on Xvfb.
x11vnc -display :99 -forever -shared -rfbport 5901 -nopw -localhost -noshm -noxdamage -noxfixes -noxrecord -wait 10 -defer 10 -ncache 0 &

sleep 2

TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s: localhost:5901\n' "$TOKEN" > /tmp/websockify.tokens

cat > /usr/share/novnc/index.html <<EOF
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#111111">
<style>
html,body{margin:0;width:100%;height:100%;background:#111;overflow:hidden}
#loading{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;font:600 16px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;background:#111;z-index:2}
</style>
</head>
<body>
<div id="loading">Opening Pocket Option…</div>
<script>
const target="/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}&logging=debug";
location.replace(target);
</script>
</body>
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
