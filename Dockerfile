FROM python:3.12-slim

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
WORKDIR /app

COPY requirements.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends git build-essential pkg-config ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt \
    && python -m playwright install --with-deps chromium \
    && mkdir -p /opt/google/chrome \
    && CHROME_BIN="$(find /ms-playwright -type f \( -path "*/chrome-linux/chrome" -o -path "*/chrome-linux64/chrome" \) | head -n 1)" \
    && test -n "$CHROME_BIN" \
    && ln -sf "$CHROME_BIN" /opt/google/chrome/chrome

COPY . .

CMD ["python", "-u", "demo_connection_test.py"]
