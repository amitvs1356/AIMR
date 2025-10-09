FROM python:3.11-slim

# 1) base tools + CA bundle (needed for TLS) – PERSISTENT
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates iputils-ping curl \
 && update-ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2) deps
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
RUN pip install pillow

# 3) app code
COPY . /app

# 4) entrypoint (we’ll tweak it next to prefer IPv4 at runtime)
ENTRYPOINT ["/app/entrypoint.sh"]
