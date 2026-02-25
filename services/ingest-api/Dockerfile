FROM ghcr.io/osgeo/gdal:ubuntu-full-latest

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

COPY pyproject.toml /app/pyproject.toml
COPY main.py /app/main.py

WORKDIR /app
RUN uv sync --no-dev

CMD ["uv", "run", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8001"]
