# Optional portable development deployment; NOT installed on the production host.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libargon2-1 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY pressure pressure
COPY web web
ENV PRESSURE_DB=/data/pressure.sqlite3 PRESSURE_WEB=/app/web
RUN useradd --uid 10001 --create-home pressure && mkdir /data && chown pressure /data
USER pressure
CMD ["python", "-m", "uvicorn", "pressure.api:app", "--host", "0.0.0.0", "--port", "8093", "--no-access-log"]
