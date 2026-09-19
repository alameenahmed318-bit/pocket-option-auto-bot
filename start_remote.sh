#!/bin/sh
set -eu

: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"

export DISPLAY=:99
Xvfb :99 -screen 0 390x844x24 -ac &
sleep 2

x11vnc -display :99 -forever -shared -rfbport 5900 -nopw -localhost -noxdamage -wait 10 -defer 10 -ncache 0 -noxfixes -noxrecord &

# Fresh per-container VNC token.
TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s: localhost:5900\n' "$TOKEN" > /tmp/websockify.tokens

# Direct mobile launcher: open Pocket Option's remote browser screen immediately.
# noVNC remains the transport/UI layer, but the user never sees its landing page.
cat > /usr/share/novnc/index.html <<EOF
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#111111">
<style>
html,body{margin:0;width:100%;height:100%;background:#111;overflow:hidden}
#go{position:fixed;inset:0;width:100%;height:100%;border:0}
#loading{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;font:600 16px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;background:#111;z-index:2}
</style>
</head>
<body>
<div id="loading">Opening Pocket Option…</div>
<iframe id="go" allow="clipboard-read; clipboard-write" src="/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}"></iframe>
<script>
const f=document.getElementById('go');
f.addEventListener('load',()=>setTimeout(()=>document.getElementById('loading').style.display='none',1200));
</script>
</body>
</html>
EOF

# Protect the VNC WebSocket with a fresh token and disable directory listings.
websockify \
  --web=/usr/share/novnc/ \
  --file-only \
  --token-plugin websockify.token_plugins.TokenFile \
  --token-source /tmp/websockify.tokens \
  "8080" &

PORT=8090 python -u remote_login.py &
exec python -u demo_connection_test.py
