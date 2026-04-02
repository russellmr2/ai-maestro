#!/bin/bash
# =============================================================================
# clone-team.sh — Clone an AI Maestro agent team for a new project
#
# Usage:
#   ./clone-team.sh \
#     --source-prefix tomelio \
#     --target-prefix mocario \
#     --target-project /home/bro/projects/Mocario \
#     --team-display-name "MOCARIO"
#
# Options:
#   --source-prefix     Prefix of source agents (e.g., "tomelio")
#   --target-prefix     Prefix for new agents (e.g., "mocario")
#   --target-project    Absolute path to new project directory
#   --team-display-name Display name for the new team in dashboard
#   --source-project    Source project path (default: auto-detected from agents)
#   --api               Maestro API URL (default: http://localhost:23000)
#   --force             Delete existing target agents before creating
# =============================================================================

set -euo pipefail

# Defaults
API="http://localhost:23000"
REGISTRY="$HOME/.aimaestro/agents/registry.json"
SOURCE_PREFIX=""
TARGET_PREFIX=""
TARGET_PROJECT=""
TEAM_DISPLAY_NAME=""
SOURCE_PROJECT=""
FORCE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --source-prefix)  SOURCE_PREFIX="$2"; shift 2 ;;
        --target-prefix)  TARGET_PREFIX="$2"; shift 2 ;;
        --target-project) TARGET_PROJECT="$2"; shift 2 ;;
        --team-display-name) TEAM_DISPLAY_NAME="$2"; shift 2 ;;
        --source-project) SOURCE_PROJECT="$2"; shift 2 ;;
        --api)            API="$2"; shift 2 ;;
        --force)          FORCE=true; shift ;;
        -h|--help)
            echo "Usage: $0 --source-prefix PREFIX --target-prefix PREFIX --target-project PATH --team-display-name NAME [--force]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required args
for var in SOURCE_PREFIX TARGET_PREFIX TARGET_PROJECT TEAM_DISPLAY_NAME; do
    if [[ -z "${!var}" ]]; then
        echo "ERROR: --$(echo $var | tr '_' '-' | tr 'A-Z' 'a-z') is required"
        exit 1
    fi
done

echo "========================================"
echo "  Clone Team: ${SOURCE_PREFIX} → ${TARGET_PREFIX}"
echo "========================================"
echo ""

# ─────────────────────────────────────────────
# Phase 1: Validate
# ─────────────────────────────────────────────
echo "[1/5] Validating prerequisites..."

# Check API
if ! curl -s -o /dev/null -w "%{http_code}" "$API/" 2>/dev/null | grep -q "200"; then
    echo "  ERROR: Maestro API not reachable at $API"
    echo "  Start the server first: cd /home/bro/projects/ai-maestro && npm run dev"
    exit 1
fi
echo "  ✓ Maestro API reachable at $API"

# Check registry
if [[ ! -f "$REGISTRY" ]]; then
    echo "  ERROR: Agent registry not found at $REGISTRY"
    exit 1
fi

# Count source agents
SOURCE_COUNT=$(python3 -c "
import json
with open('$REGISTRY') as f:
    agents = json.load(f)
print(len([a for a in agents if a.get('name','').startswith('${SOURCE_PREFIX}-') and a.get('status') != 'deleted']))
")
echo "  ✓ Found $SOURCE_COUNT source agents with prefix '${SOURCE_PREFIX}-'"

if [[ "$SOURCE_COUNT" -eq 0 ]]; then
    echo "  ERROR: No agents found with prefix '${SOURCE_PREFIX}-'"
    exit 1
fi

# Auto-detect source project if not provided
if [[ -z "$SOURCE_PROJECT" ]]; then
    SOURCE_PROJECT=$(python3 -c "
import json
with open('$REGISTRY') as f:
    agents = json.load(f)
for a in agents:
    if a.get('name','').startswith('${SOURCE_PREFIX}-') and a.get('workingDirectory'):
        print(a['workingDirectory'])
        break
")
    echo "  ✓ Auto-detected source project: $SOURCE_PROJECT"
fi

# Check source personality files
if [[ ! -d "$SOURCE_PROJECT/.claude/agents" ]]; then
    echo "  ERROR: Source personality files not found at $SOURCE_PROJECT/.claude/agents/"
    exit 1
fi
echo "  ✓ Source personality files found"

# Check for existing target agents
EXISTING_COUNT=$(python3 -c "
import json
with open('$REGISTRY') as f:
    agents = json.load(f)
print(len([a for a in agents if a.get('name','').startswith('${TARGET_PREFIX}-') and a.get('status') != 'deleted']))
")

if [[ "$EXISTING_COUNT" -gt 0 ]]; then
    if [[ "$FORCE" == "true" ]]; then
        echo "  ⚠ Found $EXISTING_COUNT existing '${TARGET_PREFIX}-' agents — deleting (--force)"
        python3 -c "
import json
with open('$REGISTRY') as f:
    agents = json.load(f)
for a in agents:
    if a.get('name','').startswith('${TARGET_PREFIX}-') and a.get('status') != 'deleted':
        import urllib.request
        req = urllib.request.Request('$API/api/agents/' + a['id'], method='DELETE')
        try:
            urllib.request.urlopen(req)
            print(f'  Deleted: {a[\"name\"]}')
        except: pass
"
        sleep 1
    else
        echo "  ERROR: $EXISTING_COUNT agents with prefix '${TARGET_PREFIX}-' already exist"
        echo "  Use --force to delete them first"
        exit 1
    fi
fi

# Create target directories
mkdir -p "$TARGET_PROJECT/.claude/agents"
echo "  ✓ Target directory ready: $TARGET_PROJECT/.claude/agents/"

echo ""

# ─────────────────────────────────────────────
# Phase 2: Create Agents via API
# ─────────────────────────────────────────────
echo "[2/5] Creating $SOURCE_COUNT agents..."

# Use Python to read source agents and create new ones via API
# Pass variables via environment to avoid quote escaping issues
SOURCE_PREFIX="$SOURCE_PREFIX" \
TARGET_PREFIX="$TARGET_PREFIX" \
TARGET_PROJECT="$TARGET_PROJECT" \
MAESTRO_API="$API" \
AGENT_REGISTRY="$REGISTRY" \
python3 << 'PYEOF' 2>&1 | tee /tmp/clone-team-output.txt
import json, urllib.request, time, sys, os

SOURCE_PREFIX = os.environ['SOURCE_PREFIX']
TARGET_PREFIX = os.environ['TARGET_PREFIX']
TARGET_PROJECT = os.environ['TARGET_PROJECT']
API = os.environ['MAESTRO_API']
REGISTRY = os.environ['AGENT_REGISTRY']

with open(REGISTRY) as f:
    agents = json.load(f)

source_agents = [a for a in agents if a.get('name','').startswith(f'{SOURCE_PREFIX}-') and a.get('status') != 'deleted']

for agent in source_agents:
    name = agent['name']
    role = name.replace(f'{SOURCE_PREFIX}-', '')
    new_name = f'{TARGET_PREFIX}-{role}'

    create_data = {
        'name': new_name,
        'program': agent.get('program', 'claude-code'),
        'taskDescription': agent.get('taskDescription', f'Agent for {new_name}').replace(SOURCE_PREFIX, TARGET_PREFIX),
        'workingDirectory': TARGET_PROJECT,
        'createSession': False,
        'role': agent.get('role', 'member'),
    }

    if agent.get('label'):
        create_data['label'] = agent['label']
    if agent.get('avatar'):
        create_data['avatar'] = agent['avatar']
    if agent.get('programArgs'):
        create_data['programArgs'] = agent['programArgs']
    if agent.get('tags'):
        create_data['tags'] = [TARGET_PREFIX if t == SOURCE_PREFIX else t for t in agent['tags']]
    if agent.get('owner'):
        create_data['owner'] = agent['owner']

    try:
        req = urllib.request.Request(
            f'{API}/api/agents',
            data=json.dumps(create_data).encode(),
            headers={'Content-Type': 'application/json'},
            method='POST'
        )
        resp = urllib.request.urlopen(req)
        result = json.loads(resp.read())
        new_id = result.get('agent', result).get('id', '')
        print(f'CREATED:{role}:{new_id}')
        sys.stderr.write(f'  ✓ Created: {new_name} ({new_id[:8]}...)\n')

        # Set personalityFile via PUT
        update_data = {'personalityFile': f'.claude/agents/{role}.md'}
        update_req = urllib.request.Request(
            f'{API}/api/agents/{new_id}',
            data=json.dumps(update_data).encode(),
            headers={'Content-Type': 'application/json'},
            method='PATCH'
        )
        urllib.request.urlopen(update_req)
        time.sleep(0.3)
    except Exception as e:
        sys.stderr.write(f'  ✗ Failed: {new_name} — {e}\n')
PYEOF

# Extract agent IDs from output
AGENT_ID_LIST=$(grep "^CREATED:" /tmp/clone-team-output.txt | cut -d: -f3 | tr '\n' ',' | sed 's/,$//')

echo ""

# ─────────────────────────────────────────────
# Phase 3: Create Team via API
# ─────────────────────────────────────────────
echo "[3/5] Creating team '${TEAM_DISPLAY_NAME}'..."

# Build agentIds JSON array
AGENT_IDS_JSON=$(grep "^CREATED:" /tmp/clone-team-output.txt | cut -d: -f3 | python3 -c "
import sys, json
ids = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(ids))
")

TEAM_RESPONSE=$(curl -s -X POST "$API/api/teams" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${TEAM_DISPLAY_NAME}\",
        \"description\": \"${TEAM_DISPLAY_NAME} development team (${SOURCE_COUNT} agents)\",
        \"agentIds\": ${AGENT_IDS_JSON}
    }")

TEAM_ID=$(echo "$TEAM_RESPONSE" | python3 -c "import json,sys; r=json.load(sys.stdin); print(r.get('id', r.get('team',{}).get('id','unknown')))" 2>/dev/null || echo "unknown")
echo "  ✓ Team created: ${TEAM_DISPLAY_NAME} (${TEAM_ID})"

echo ""

# ─────────────────────────────────────────────
# Phase 4: Clone & Adapt Personality Files
# ─────────────────────────────────────────────
echo "[4/5] Cloning personality files..."

SOURCE_PREFIX="$SOURCE_PREFIX" \
TARGET_PREFIX="$TARGET_PREFIX" \
SOURCE_PROJECT_PATH="$SOURCE_PROJECT" \
TARGET_PROJECT_PATH="$TARGET_PROJECT" \
python3 << 'PYEOF2'
import os, re, glob

SOURCE_PREFIX = os.environ['SOURCE_PREFIX']
TARGET_PREFIX = os.environ['TARGET_PREFIX']
SOURCE_PROJECT = os.environ['SOURCE_PROJECT_PATH']
TARGET_PROJECT = os.environ['TARGET_PROJECT_PATH']

# Generic expertise per role (stripped to role-only)
GENERIC_EXPERTISE = {
    'maya-pm': ['- Project management, team coordination, task prioritization'],
    'rex-backend': ['- Backend development, API design, server-side architecture'],
    'pixel-frontend': ['- Frontend development, UI/UX implementation, component design'],
    'hawkeye-qa': ['- Quality assurance, code review, test automation'],
    'sentinel-git': ['- Git workflow management, branch strategy, merge coordination'],
    'forge-devops': ['- Infrastructure, CI/CD, Docker, deployment automation'],
    'shield-security': ['- Application security, vulnerability assessment, hardening'],
    'oracle-ai': ['- AI/ML integration, prompt engineering, model optimization'],
    'iris-design': ['- UI/UX design, design systems, accessibility'],
    'luna-marketing': ['- Product marketing, copywriting, go-to-market strategy'],
    'scribe-docs': ['- Technical writing, API documentation, architecture docs'],
    'turbo-perf': ['- Performance optimization, profiling, load testing'],
    'vault-data': ['- Database design, data modeling, query optimization'],
}

# Section headers that contain project-specific file paths to strip
FILE_SECTIONS = [
    'Key Files You Own',
    'Key Files You Review',
    'Key Files You Profile',
]

src_dir = os.path.join(SOURCE_PROJECT, '.claude', 'agents')
dst_dir = os.path.join(TARGET_PROJECT, '.claude', 'agents')

for src_file in sorted(glob.glob(os.path.join(src_dir, '*.md'))):
    filename = os.path.basename(src_file)
    role = filename.replace('.md', '')
    dst_file = os.path.join(dst_dir, filename)

    with open(src_file, 'r') as f:
        content = f.read()

    # Step A: sed-style replacements (order matters: prefix- before bare prefix)
    content = content.replace(f'{SOURCE_PREFIX}-', f'{TARGET_PREFIX}-')
    # Case-sensitive project name (capitalize first letter)
    source_cap = SOURCE_PREFIX[0].upper() + SOURCE_PREFIX[1:]
    target_cap = TARGET_PREFIX[0].upper() + TARGET_PREFIX[1:]
    content = content.replace(source_cap, target_cap)
    content = content.replace(SOURCE_PREFIX, TARGET_PREFIX)
    content = content.replace(SOURCE_PROJECT, TARGET_PROJECT)

    # Step B: Strip project-specific sections
    lines = content.split('\n')
    new_lines = []
    i = 0
    while i < len(lines):
        line = lines[i]

        # Check for Expertise section
        if line.startswith('## Expertise'):
            new_lines.append(line)
            i += 1
            # Skip content until next ## header
            expertise = GENERIC_EXPERTISE.get(role, ['- (To be defined as the project develops)'])
            new_lines.extend(expertise)
            while i < len(lines) and not lines[i].startswith('## '):
                i += 1
            new_lines.append('')
            continue

        # Check for file ownership sections
        is_file_section = False
        for section_name in FILE_SECTIONS:
            if line.startswith(f'## {section_name}'):
                is_file_section = True
                break

        if is_file_section:
            new_lines.append(line)
            i += 1
            new_lines.append('- (To be defined as the project develops)')
            # Skip content until next ## header
            while i < len(lines) and not lines[i].startswith('## '):
                i += 1
            new_lines.append('')
            continue

        # Check for project-specific knowledge in Rules (lines referencing specific files/tech)
        # Keep the line unless it references very specific Tomelio internals
        skip_patterns = [
            'EnhancedRecipeGenerationWorkflow',
            'OLD_ prefix is legacy',
            'asyncpg is the database driver',
            'WindowsSelectorEventLoopPolicy',
            'enhanced_recipe_workflow',
            'recipe_generation_workflow',
            'cookbook_backend',
            'cookbook_postgres',
        ]

        skip_line = False
        for pattern in skip_patterns:
            # Check against the ORIGINAL line (before replacements were applied)
            if pattern.lower() in line.lower():
                skip_line = True
                break

        if not skip_line:
            new_lines.append(line)

        i += 1

    # Remove consecutive blank lines (cleanup)
    cleaned = []
    prev_blank = False
    for line in new_lines:
        if line.strip() == '':
            if not prev_blank:
                cleaned.append(line)
            prev_blank = True
        else:
            cleaned.append(line)
            prev_blank = False

    with open(dst_file, 'w') as f:
        f.write('\n'.join(cleaned))

    print(f'  ✓ {filename}')
PYEOF2

echo ""

# ─────────────────────────────────────────────
# Phase 5: Generate Startup Script
# ─────────────────────────────────────────────
echo "[5/5] Generating startup script..."

STARTUP_SCRIPT="$HOME/Desktop/start-${TARGET_PREFIX}.sh"

# Use start-mocario.sh as template (clean: agents-only, no Docker/infra)
# Falls back to repo copy if neither exists
STARTUP_TEMPLATE="$HOME/Desktop/start-mocario.sh"
if [[ ! -f "$STARTUP_TEMPLATE" ]]; then
    STARTUP_TEMPLATE="/home/bro/projects/ai-maestro/start-tomelio.sh"
    echo "  ⚠ No clean startup template found, using repo fallback"
fi

sed -e "s/mocario-/${TARGET_PREFIX}-/g" \
    -e "s/Mocario/${TEAM_DISPLAY_NAME}/g" \
    -e "s/mocario/${TARGET_PREFIX}/g" \
    -e "s|/home/bro/projects/Mocario|${TARGET_PROJECT}|g" \
    "$STARTUP_TEMPLATE" > "$STARTUP_SCRIPT"

chmod +x "$STARTUP_SCRIPT"
echo "  ✓ Created: $STARTUP_SCRIPT"

echo ""

# ─────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────
echo "========================================"
echo "  VALIDATION"
echo "========================================"

# Count new agents
NEW_COUNT=$(python3 -c "
import json
with open('$REGISTRY') as f:
    agents = json.load(f)
count = len([a for a in agents if a.get('name','').startswith('${TARGET_PREFIX}-') and a.get('status') != 'deleted'])
print(count)
")
echo "  Agents created: ${NEW_COUNT}/${SOURCE_COUNT}"

# Count personality files
FILE_COUNT=$(ls -1 "$TARGET_PROJECT/.claude/agents/"*.md 2>/dev/null | wc -l)
echo "  Personality files: ${FILE_COUNT}/${SOURCE_COUNT}"

# Team info
echo "  Team: ${TEAM_DISPLAY_NAME} (${TEAM_ID})"
echo "  Dashboard: ${API}"

echo ""
echo "========================================"
echo "  DONE! ${TEAM_DISPLAY_NAME} team is ready."
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Initialize git repo in ${TARGET_PROJECT} (if not done)"
echo "  2. Create worktree branches: work/backend, work/frontend, work/docs, work/devops"
echo "  3. Start agents: ./start-${TARGET_PREFIX}.sh"
echo "  4. Customize personality files in ${TARGET_PROJECT}/.claude/agents/ as the project evolves"

# Cleanup
rm -f /tmp/clone-team-output.txt /tmp/clone-team-results.txt
