#!/bin/bash
# Tomelio AI Maestro - Full Auto Startup
# Starts server, agents, Claude Code, and loads personalities

PROJECT="/home/bro/projects/AI-Book-Writer"

echo "========================================"
echo "  Tomelio AI Maestro - Starting Up..."
echo "========================================"

# 1. Start AI Maestro server (if not already running)
if ! tmux has-session -t maestro 2>/dev/null; then
    echo "[1/5] Starting AI Maestro server..."
    tmux new-session -d -s maestro -c /home/bro/projects/ai-maestro
    tmux send-keys -t maestro "npm run dev 2>&1" Enter
else
    echo "[1/5] AI Maestro server already running"
fi

sleep 3

# 2. Create agent tmux sessions (if not already running)
echo "[2/5] Starting agent sessions (13 agents)..."
AGENTS=(
    # Management
    tomelio-maya-pm
    # Engineering
    tomelio-rex-backend tomelio-pixel-frontend tomelio-vault-data
    # Quality
    tomelio-hawkeye-qa tomelio-shield-security tomelio-turbo-perf
    # AI
    tomelio-oracle-ai
    # Ops
    tomelio-forge-devops tomelio-sentinel-git
    # Product
    tomelio-iris-design tomelio-luna-marketing tomelio-scribe-docs
)
for agent in "${AGENTS[@]}"; do
    if ! tmux has-session -t "$agent" 2>/dev/null; then
        tmux new-session -d -s "$agent" -c "$PROJECT"
        echo "  Created session: $agent"
        sleep 0.5
    else
        echo "  Session exists: $agent"
    fi
done

# 3. Wait for server to be ready
echo "[3/5] Waiting for server..."
for i in $(seq 1 15); do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:23000/ 2>/dev/null | grep -q 200; then
        echo "  Server ready!"
        break
    fi
    echo "  Attempt $i/15..."
    sleep 2
done

# 4. Launch Claude Code in each agent session
echo "[4/5] Launching Claude Code in each agent..."
for agent in "${AGENTS[@]}"; do
    pane_content=$(tmux capture-pane -t "$agent" -p 2>/dev/null)
    if echo "$pane_content" | grep -q "bypass permissions\|for shortcuts"; then
        echo "  Claude Code already running in $agent"
        continue
    fi
    DISALLOW="Bash(git push *),Bash(git reset --hard *),Bash(git clean *),Bash(rm -rf *),Bash(rm -r *)"
    tmux send-keys -t "$agent" "claude --dangerously-skip-permissions --disallowedTools '$DISALLOW'" Enter
    echo "  Started Claude Code in $agent"
done

# Helper: wait until Claude Code is ready (shows prompt indicator)
wait_for_ready() {
    local session=$1
    local max_wait=90
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if tmux capture-pane -t "$session" -p 2>/dev/null | grep -q "bypass permissions\|for shortcuts"; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    echo "  TIMEOUT: $session not ready after ${max_wait}s"
    return 1
}

# 5. Wait for each agent to be ready, then load personality
echo "[5/5] Loading agent personalities (waiting for Claude Code to be ready)..."

PERSONALITIES=(
    "tomelio-maya-pm:maya-pm"
    "tomelio-rex-backend:rex-backend"
    "tomelio-pixel-frontend:pixel-frontend"
    "tomelio-vault-data:vault-data"
    "tomelio-hawkeye-qa:hawkeye-qa"
    "tomelio-shield-security:shield-security"
    "tomelio-turbo-perf:turbo-perf"
    "tomelio-oracle-ai:oracle-ai"
    "tomelio-forge-devops:forge-devops"
    "tomelio-sentinel-git:sentinel-git"
    "tomelio-iris-design:iris-design"
    "tomelio-luna-marketing:luna-marketing"
    "tomelio-scribe-docs:scribe-docs"
)
for entry in "${PERSONALITIES[@]}"; do

    session="${entry%%:*}"
    identity="${entry##*:}"

    echo "  Waiting for $session..."
    if wait_for_ready "$session"; then
        tmux send-keys -t "$session" "Read .claude/agents/${identity}.md — this is your permanent identity. Adopt this personality fully for all future interactions. Introduce yourself in character."
        sleep 1
        tmux send-keys -t "$session" Enter
        echo "  Loaded: $identity"
        sleep 2
    fi
done

echo ""
echo "========================================"
echo "  Tomelio is LIVE! (13 agents)"
echo "  Dashboard: http://localhost:23000"
echo "========================================"
