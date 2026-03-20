#!/bin/bash
set -e

echo "── Aura Agent starting ──"

# ── 1. Authentication ──
if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    if claude auth status > /dev/null 2>&1; then
        echo "✓ Claude Code: authenticated"
    else
        # Report awaiting-auth status to Aura
        curl -s -X POST "$AURA_URL/api/containers/$CONTAINER_ID/heartbeat" \
          -H "Authorization: Bearer $AURA_API_KEY" \
          -H "Content-Type: application/json" \
          -d '{"awaitingAuth": true}' || true

        echo "⏳ Waiting for auth via web terminal..."
        claude auth login
        # Blocks until admin completes OAuth in the web terminal
    fi
else
    echo "✓ CLI tool: ${CLI_TOOL} (API key auth, no interactive login needed)"
fi

# ── 2. SSH keys ──
mkdir -p ~/.ssh
ssh-keyscan github.com gitlab.com >> ~/.ssh/known_hosts 2>/dev/null || true

if [ -d /keys ] && [ "$(ls -A /keys 2>/dev/null)" ]; then
    for key in /keys/*; do
        chmod 600 "$key" 2>/dev/null
    done
    eval "$(ssh-agent -s)"
    ssh-add /keys/* 2>/dev/null || true
    echo "✓ SSH keys loaded"
else
    echo "– No SSH keys mounted"
fi

# ── 3. Clone or pull repositories ──
if [ -n "$GIT_REPOS" ] && [ "$GIT_REPOS" != "[]" ]; then
    echo "$GIT_REPOS" | python3 -c "
import json, sys, subprocess, os
for repo in json.load(sys.stdin):
    path = repo['localPath']
    url  = repo['cloneUrl']
    branch = repo.get('branch', 'main')
    if os.path.exists(os.path.join(path, '.git')):
        print(f'  pulling {path}')
        subprocess.run(['git', '-C', path, 'pull', '--ff-only'], check=False)
    else:
        print(f'  cloning {url} → {path}')
        os.makedirs(path, exist_ok=True)
        subprocess.run(['git', 'clone', '-b', branch, url, path], check=True)
"
    echo "✓ Repositories ready"
else
    echo "– No repositories configured"
fi

# ── 4. Configure MCP server ──
# Write .env for the MCP server
cat > /opt/aura/mcp-server/.env <<EOF
AURA_URL=$AURA_URL
AURA_API_KEY=$AURA_API_KEY
EOF

if [ "${CLI_TOOL:-claude}" = "claude" ]; then
    claude mcp add --scope user aura -- python3 /opt/aura/mcp-server/server.py
    echo "✓ MCP server registered"
fi

# ── 5. Generate configuration files ──
# Write .env for the SignalR client
cat > /opt/aura/signalr-client/.env <<EOF
KANBAN_URL=$AURA_URL
API_KEY=$AURA_API_KEY
PORT=${SIGNALR_CLIENT_PORT:-9002}
EOF

# Generate subscription.json from env vars
python3 /opt/aura/generate-subscription.py
echo "✓ Subscription config generated"

# Generate cli_tools.json
python3 -c "
import json
config = {
    'defaultTool': '${CLI_TOOL:-claude}',
    'userMappings': {}
}
model = '${CLI_MODEL:-}'
if model:
    config['defaultModel'] = model
with open('/opt/aura/signalr-client/cli_tools.json', 'w') as f:
    json.dump(config, f, indent=2)
"
echo "✓ CLI tools config generated"

# ── 6. Start SignalR client ──
echo "── Starting SignalR client ──"
cd /opt/aura/signalr-client
exec python3 signalr_receiver.py
