FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates build-essential pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir -r requirements.txt \
    && playwright install --with-deps firefox chromium \
    && playwright install chrome --force

COPY . .

# Force Railway to rebuild the browser layer after the Playwright browser fix.
RUN echo "pocket-option-playwright-browser-fix-2026-09-19"

CMD ["python", "-u", "demo_connection_test.py"]
