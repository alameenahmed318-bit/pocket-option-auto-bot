#!/bin/sh
set -eu

: "${REMOTE_LOGIN_PASSWORD:?Set REMOTE_LOGIN_PASSWORD in Railway Variables}"
: "${PORT:?Railway PORT is required}"

export DISPLAY=:99
Xvfb :99 -screen 0 392x844x24 -ac +extension GLX +extension RANDR &
sleep 3

VNC_PORT=5902
x11vnc -display :99 -forever -shared -rfbport "$VNC_PORT" -nopw -localhost -noshm -noxdamage -noxfixes -noxrecord -wait 10 -defer 10 -ncache 0 &
sleep 2

TOKEN="$(python -c 'import secrets; print(secrets.token_urlsafe(24))')"
printf '%s: localhost:%s\n' "$TOKEN" "$VNC_PORT" > /tmp/websockify.tokens

cat > /usr/share/novnc/index.html <<EOF
<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
<meta http-equiv="refresh" content="0;url=/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}">
<script>location.replace("/vnc.html?autoconnect=1&reconnect=1&reconnect_delay=1000&resize=scale&scaleViewport=true&view_only=false&path=websockify%3Ftoken%3D${TOKEN}");</script>
</head><body></body></html>
EOF

# websockify serves noVNC and proxies WebSocket traffic internally.
websockify --web=/usr/share/novnc/ --file-only   --token-plugin websockify.token_plugins.TokenFile   --token-source /tmp/websockify.tokens   127.0.0.1:6080 &

# Protect the public Railway endpoint with the existing Railway password.
HASH="$(openssl passwd -apr1 "$REMOTE_LOGIN_PASSWORD")"
printf 'admin:%s\n' "$HASH" > /etc/nginx/.htpasswd

cat > /etc/nginx/conf.d/pocket-vnc.conf <<EOF
server {
    listen ${PORT};
    server_name _;

    auth_basic "Pocket Option Demo Bot";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location /websockify {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    location /websockify {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        root /usr/share/novnc;
        try_files \$uri \$uri/ /vnc.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
nginx -t
nginx

# The bot's own status HTTP server stays internal so it does not compete for Railway's PORT.
exec env BOT_HTTP_PORT=8081 python -u remote_login.py
