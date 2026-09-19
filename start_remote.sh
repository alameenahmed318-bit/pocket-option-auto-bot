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

# Open the full noVNC UI by default. It has the mobile on-screen keyboard.
cat > /usr/share/novnc/index.html <<EOF
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="0; url=/vnc.html?autoconnect=1&resize=scale&path=websockify%3Ftoken%3D${TOKEN}&scaleViewport=true&resize=scale&viewOnly=false">
</head>
<body>Opening secure noVNC...</body>
</html>
EOF

# Protect the VNC WebSocket with a fresh token and disable directory listings.
websockify \
  --web=/usr/share/novnc/ \
  --file-only \
  --token-plugin websockify.token_plugins.TokenFile \
  --token-source /tmp/websockify.tokens \
  6080 localhost:5900 &

python -u remote_login.py &
exec python -u demo_connection_test.py
