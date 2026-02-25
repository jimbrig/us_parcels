FROM ghcr.io/osgeo/gdal:ubuntu-full-latest

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip python3-venv && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --no-cache-dir fastapi uvicorn[standard] psycopg2-binary

COPY main.py /app/main.py

WORKDIR /app
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
