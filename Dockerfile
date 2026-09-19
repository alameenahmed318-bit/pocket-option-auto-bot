FROM mcr.microsoft.com/playwright/python:v1.55.0-noble

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Build marker: 2026-09-19-login-timeout-fix
CMD ["python", "-u", "browser_demo_test.py"]
