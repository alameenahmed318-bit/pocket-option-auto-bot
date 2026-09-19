FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# API-only demo connection test; no browser automation.
CMD ["python", "-u", "demo_connection_test.py"]
