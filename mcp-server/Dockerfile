FROM python:3.12-slim

WORKDIR /app

COPY pyproject.toml README.md ./
COPY solar_db ./solar_db
COPY mcp-server ./mcp-server

RUN pip install --no-cache-dir -e . && \
    pip install --no-cache-dir -e ./mcp-server

ENV PYTHONUNBUFFERED=1 \
    SOLAR_DB_PATH=/data/solar_system.sqlite \
    MCP_TRANSPORT=http \
    MCP_PORT=8002

EXPOSE 8002

CMD ["python", "mcp-server/server.py", "--transport", "http"]
