FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates build-essential pkg-config xvfb x11vnc novnc websockify \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt \
    && playwright install --with-deps chromium

COPY . .
RUN mkdir -p /data
# Ensure Railway rebuilds after remote-login bootstrap files are present.
RUN echo "remote-login-bootstrap-2026-09-19-v2"
COPY start_remote.sh /app/start_remote.sh
RUN chmod +x /app/start_remote.sh
CMD ["/app/start_remote.sh"]
