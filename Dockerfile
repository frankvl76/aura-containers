FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ──
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    curl \
    python3 \
    python3-pip \
    python3-venv \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Node.js (for Claude Code) ──
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ── Claude Code CLI ──
RUN npm install -g @anthropic-ai/claude-code

# ── ttyd (web terminal) ──
RUN apt-get update && apt-get install -y --no-install-recommends ttyd \
    && rm -rf /var/lib/apt/lists/*

# ── Clone SignalR client and MCP server from GitHub (private repos) ──
RUN --mount=type=secret,id=github_token \
    GITHUB_TOKEN=$(cat /run/secrets/github_token) \
    && git clone https://x-access-token:${GITHUB_TOKEN}@github.com/frankvl76/aura-signalr-client.git /opt/aura/signalr-client \
    && git clone https://x-access-token:${GITHUB_TOKEN}@github.com/frankvl76/aura-mcp-server.git /opt/aura/mcp-server

# ── Install Python dependencies ──
RUN pip3 install --no-cache-dir --break-system-packages \
    -r /opt/aura/signalr-client/requirements.txt \
    -r /opt/aura/mcp-server/requirements.txt

# ── Entrypoint + helpers ──
COPY entrypoint.sh /opt/aura/entrypoint.sh
COPY claude-auth.py /opt/aura/claude-auth.py
COPY generate-subscription.py /opt/aura/generate-subscription.py
RUN chmod +x /opt/aura/entrypoint.sh

ENTRYPOINT ["/opt/aura/entrypoint.sh"]
