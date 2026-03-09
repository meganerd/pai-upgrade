#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# upgrade-pai.sh — Safe, automated PAI upgrade with learning preservation
#
# Usage:
#   ./upgrade-pai.sh              # Upgrade to latest release
#   ./upgrade-pai.sh v4.0.3       # Upgrade to specific version
#   ./upgrade-pai.sh --dry-run    # Show what would change
#   ./upgrade-pai.sh --no-backup  # Skip backup step
# ─────────────────────────────────────────────────────────────────────

PAI_DIR="${HOME}/.claude"
REPO_URL="https://github.com/danielmiessler/Personal_AI_Infrastructure.git"
DRY_RUN=false
SKIP_BACKUP=false
TARGET_VERSION=""
BACKUP_DIR=""
TEMP_DIR=""

# ─── Colors ──────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1" >&2; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

# ─── Cleanup ─────────────────────────────────────────────────────────

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# ─── Argument Parsing ────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --no-backup)  SKIP_BACKUP=true; shift ;;
        --help|-h)
            echo "Usage: upgrade-pai.sh [OPTIONS] [VERSION]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would change without modifying anything"
            echo "  --no-backup   Skip the backup step (use if you've backed up manually)"
            echo "  --help, -h    Show this help message"
            echo ""
            echo "Arguments:"
            echo "  VERSION       Target version tag (e.g., v4.0.3). Default: latest release."
            exit 0
            ;;
        v*)           TARGET_VERSION="$1"; shift ;;
        *)            err "Unknown argument: $1"; exit 1 ;;
    esac
done

# ─── Phase 1: Pre-flight Checks ─────────────────────────────────────

header "Phase 1: Pre-flight Checks"

# Check required tools
for cmd in bun git jq rsync; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is required but not found on PATH"
        exit 1
    fi
    log "$cmd found: $(command -v "$cmd")"
done

# Check PAI installation exists
if [[ ! -f "$PAI_DIR/settings.json" ]]; then
    err "No PAI installation found at $PAI_DIR (missing settings.json)"
    exit 1
fi
log "PAI installation found at $PAI_DIR"

# Read current version
CURRENT_VERSION=$(jq -r '.version // "unknown"' "$PAI_DIR/settings.json")
CURRENT_ALGO=$(jq -r '.algorithmVersion // "unknown"' "$PAI_DIR/settings.json")
info "Current version: PAI v${CURRENT_VERSION} (Algorithm v${CURRENT_ALGO})"

# Resolve target version
if [[ -z "$TARGET_VERSION" ]]; then
    info "No version specified, fetching latest release tag..."
    if command -v gh &>/dev/null; then
        TARGET_VERSION=$(gh api repos/danielmiessler/Personal_AI_Infrastructure/releases/latest --jq '.tag_name' 2>/dev/null || true)
    fi
    if [[ -z "$TARGET_VERSION" ]]; then
        TARGET_VERSION=$(git ls-remote --tags --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null | head -1 | sed 's|.*refs/tags/||')
    fi
    if [[ -z "$TARGET_VERSION" ]]; then
        err "Could not determine latest release. Specify a version: ./upgrade-pai.sh v4.0.3"
        exit 1
    fi
fi
info "Target version: ${TARGET_VERSION}"

# Strip leading 'v' for comparison
TARGET_NUM="${TARGET_VERSION#v}"
if [[ "$CURRENT_VERSION" == "$TARGET_NUM" ]]; then
    warn "Already at version ${CURRENT_VERSION}. Nothing to do."
    exit 0
fi

# Check disk space (need ~75MB)
AVAILABLE_KB=$(df -k "$HOME" | awk 'NR==2 {print $4}')
if [[ "$AVAILABLE_KB" -lt 76800 ]]; then
    err "Insufficient disk space. Need ~75MB, have $((AVAILABLE_KB / 1024))MB"
    exit 1
fi
log "Disk space OK ($((AVAILABLE_KB / 1024))MB available)"

if $DRY_RUN; then
    warn "DRY RUN — no changes will be made"
fi

# ─── Phase 2: Backup ────────────────────────────────────────────────

header "Phase 2: Backup"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${HOME}/.claude-backup-${TIMESTAMP}"

if $SKIP_BACKUP; then
    warn "Skipping backup (--no-backup)"
else
    if $DRY_RUN; then
        info "Would create backup at: $BACKUP_DIR"
    else
        info "Creating backup at: $BACKUP_DIR"
        rsync -a "$PAI_DIR/" "$BACKUP_DIR/"

        # Verify backup integrity
        CHECKS_PASSED=0
        CHECKS_TOTAL=0
        for check_path in \
            "settings.json" \
            "CLAUDE.md.template" \
            "hooks" \
            "skills" \
            "MEMORY" \
            "PAI/USER"; do
            CHECKS_TOTAL=$((CHECKS_TOTAL + 1))
            if [[ -e "$BACKUP_DIR/$check_path" ]]; then
                CHECKS_PASSED=$((CHECKS_PASSED + 1))
            else
                warn "Backup missing: $check_path (may not exist in source either)"
            fi
        done

        # Check auto-memory (path varies)
        if [[ -d "$BACKUP_DIR/projects" ]]; then
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        fi
        CHECKS_TOTAL=$((CHECKS_TOTAL + 1))

        BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
        log "Backup complete: $BACKUP_DIR ($BACKUP_SIZE, $CHECKS_PASSED/$CHECKS_TOTAL checks passed)"
    fi
fi

# ─── Phase 3: Fetch Release ─────────────────────────────────────────

header "Phase 3: Fetch Release"

TEMP_DIR=$(mktemp -d /tmp/pai-upgrade-XXXXXX)

if $DRY_RUN; then
    info "Would clone $REPO_URL tag $TARGET_VERSION to $TEMP_DIR"
else
    info "Cloning $TARGET_VERSION (shallow)..."
    git clone --depth 1 --branch "$TARGET_VERSION" "$REPO_URL" "$TEMP_DIR/repo" 2>&1 | tail -1
fi

# Find the release directory — try versioned path first, then root .claude/
RELEASE_DIR=""
VERSION_DIR="$TEMP_DIR/repo/Releases/${TARGET_VERSION}/.claude"
ROOT_CLAUDE="$TEMP_DIR/repo/.claude"

if ! $DRY_RUN; then
    if [[ -d "$VERSION_DIR" ]]; then
        RELEASE_DIR="$VERSION_DIR"
        log "Release found at: Releases/${TARGET_VERSION}/.claude/"
    elif [[ -d "$ROOT_CLAUDE" ]]; then
        RELEASE_DIR="$ROOT_CLAUDE"
        log "Release found at: .claude/ (root)"
    else
        err "Could not find release files in cloned repo"
        err "Checked: Releases/${TARGET_VERSION}/.claude/ and .claude/"
        exit 1
    fi
fi

# ─── Phase 4: Selective Sync — System Files ─────────────────────────

header "Phase 4: Selective Sync"

# Paths that are NEVER overwritten (sacred user data)
EXCLUDE_PATTERNS=(
    "PAI/USER/"
    "MEMORY/"
    "projects/"
    "settings.json"
    ".credentials.json"
    "mcp-needs-auth-cache.json"
    "CLAUDE.md"
)

RSYNC_EXCLUDES=()
for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    RSYNC_EXCLUDES+=(--exclude="$pattern")
done

if $DRY_RUN; then
    info "Would sync system files with these exclusions:"
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        info "  --exclude='$pattern'"
    done
    if [[ -n "$RELEASE_DIR" ]]; then
        info "Dry-run rsync preview:"
        rsync -a --dry-run --itemize-changes \
            --backup --suffix=.pre-upgrade \
            "${RSYNC_EXCLUDES[@]}" \
            "$RELEASE_DIR/" "$PAI_DIR/" 2>/dev/null | head -40
    fi
else
    info "Syncing system files (preserving USER/, MEMORY/, projects/, settings.json)..."

    # Count files before
    BEFORE_COUNT=$(find "$PAI_DIR" -type f | wc -l)

    rsync -a \
        --backup --suffix=.pre-upgrade \
        "${RSYNC_EXCLUDES[@]}" \
        "$RELEASE_DIR/" "$PAI_DIR/"

    AFTER_COUNT=$(find "$PAI_DIR" -type f | wc -l)
    log "System files synced (files: $BEFORE_COUNT → $AFTER_COUNT)"

    # Count .pre-upgrade backup files created
    BACKUP_FILES=$(find "$PAI_DIR" -name "*.pre-upgrade" -type f 2>/dev/null | wc -l)
    if [[ "$BACKUP_FILES" -gt 0 ]]; then
        info "$BACKUP_FILES overwritten files backed up with .pre-upgrade suffix"
    fi
fi

# ─── Phase 5: Settings Merge ────────────────────────────────────────

header "Phase 5: Settings Merge"

if $DRY_RUN; then
    info "Would deep-merge settings.json (current config wins conflicts, release adds new fields)"
else
    RELEASE_SETTINGS="$RELEASE_DIR/settings.json"
    CURRENT_SETTINGS="$PAI_DIR/settings.json"

    if [[ ! -f "$RELEASE_SETTINGS" ]]; then
        warn "No settings.json in release — skipping merge"
    else
        # Deep merge: release is base, current overrides, then force version from release
        RELEASE_VERSION=$(jq -r '.version // ""' "$RELEASE_SETTINGS")
        RELEASE_ALGO_VERSION=$(jq -r '.algorithmVersion // ""' "$RELEASE_SETTINGS")

        jq -s --arg ver "$RELEASE_VERSION" --arg algo "$RELEASE_ALGO_VERSION" \
            '.[0] * .[1] * {version: $ver, algorithmVersion: $algo}' \
            "$RELEASE_SETTINGS" "$CURRENT_SETTINGS" \
            > "$PAI_DIR/settings.json.tmp"

        # Validate before replacing
        if jq . "$PAI_DIR/settings.json.tmp" > /dev/null 2>&1; then
            mv "$PAI_DIR/settings.json.tmp" "$PAI_DIR/settings.json"
            log "Settings merged (version → ${RELEASE_VERSION}, algorithm → ${RELEASE_ALGO_VERSION})"

            # Report what was preserved
            ENV_KEYS=$(jq -r '.env // {} | keys | length' "$PAI_DIR/settings.json")
            HOOK_EVENTS=$(jq -r '.hooks // {} | keys | length' "$PAI_DIR/settings.json")
            info "Preserved: $ENV_KEYS env vars, $HOOK_EVENTS hook event types"
        else
            err "Merged settings.json is invalid JSON — keeping original"
            rm -f "$PAI_DIR/settings.json.tmp"
        fi
    fi
fi

# ─── Phase 6: Verify MEMORY/ Integrity ──────────────────────────────

header "Phase 6: Verify MEMORY/ Integrity"

if $DRY_RUN; then
    info "Would verify MEMORY/ directory integrity"
else
    MEMORY_OK=true

    if [[ ! -d "$PAI_DIR/MEMORY" ]]; then
        err "MEMORY/ directory missing!"
        MEMORY_OK=false
    fi

    for check in \
        "MEMORY/LEARNING" \
        "MEMORY/WORK" \
        "MEMORY/STATE"; do
        if [[ ! -d "$PAI_DIR/$check" ]]; then
            warn "$check missing"
            MEMORY_OK=false
        fi
    done

    if [[ -f "$PAI_DIR/MEMORY/LEARNING/SIGNALS/ratings.jsonl" ]]; then
        RATINGS_LINES=$(wc -l < "$PAI_DIR/MEMORY/LEARNING/SIGNALS/ratings.jsonl")
        log "Learning signals intact: $RATINGS_LINES ratings"
    else
        warn "ratings.jsonl missing or empty"
    fi

    if [[ -d "$PAI_DIR/MEMORY/WORK" ]]; then
        PRD_COUNT=$(find "$PAI_DIR/MEMORY/WORK" -mindepth 1 -maxdepth 1 -type d | wc -l)
        log "Work PRDs intact: $PRD_COUNT sessions"
    fi

    if [[ -f "$PAI_DIR/MEMORY/STATE/work.json" ]]; then
        log "State registry (work.json) intact"
    else
        warn "work.json missing"
    fi

    if ! $MEMORY_OK && [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/MEMORY" ]]; then
        warn "Restoring MEMORY/ from backup..."
        rsync -a "$BACKUP_DIR/MEMORY/" "$PAI_DIR/MEMORY/"
        log "MEMORY/ restored from backup"
    elif ! $MEMORY_OK; then
        err "MEMORY/ damaged and no backup available!"
    fi
fi

# ─── Phase 7: Regenerate Derived Files ───────────────────────────────

header "Phase 7: Regenerate Derived Files"

if $DRY_RUN; then
    info "Would run: bun $PAI_DIR/PAI/Tools/BuildCLAUDE.ts"
    info "Would run: bun $PAI_DIR/PAI/Tools/RebuildPAI.ts"
else
    # Regenerate CLAUDE.md
    if [[ -f "$PAI_DIR/PAI/Tools/BuildCLAUDE.ts" ]]; then
        info "Regenerating CLAUDE.md..."
        (cd "$PAI_DIR" && bun PAI/Tools/BuildCLAUDE.ts 2>&1) | tail -2
        if [[ -f "$PAI_DIR/CLAUDE.md" ]]; then
            log "CLAUDE.md regenerated"
        else
            err "CLAUDE.md generation failed"
        fi
    else
        warn "BuildCLAUDE.ts not found — skipping CLAUDE.md regeneration"
    fi

    # Regenerate SKILL.md
    if [[ -f "$PAI_DIR/PAI/Tools/RebuildPAI.ts" ]]; then
        info "Regenerating SKILL.md..."
        (cd "$PAI_DIR" && bun PAI/Tools/RebuildPAI.ts 2>&1) | tail -2
        if [[ -f "$PAI_DIR/PAI/SKILL.md" ]]; then
            log "SKILL.md regenerated"
        else
            warn "SKILL.md generation failed (Components/ may not exist in this version)"
        fi
    else
        warn "RebuildPAI.ts not found — skipping SKILL.md regeneration"
    fi
fi

# ─── Phase 8: Post-Upgrade Validation ───────────────────────────────

header "Phase 8: Post-Upgrade Validation"

if $DRY_RUN; then
    info "Would validate post-upgrade state"
else
    PASS=0
    FAIL=0
    TOTAL=0

    validate() {
        TOTAL=$((TOTAL + 1))
        if eval "$2"; then
            log "$1"
            PASS=$((PASS + 1))
        else
            err "$1"
            FAIL=$((FAIL + 1))
        fi
    }

    validate "settings.json is valid JSON" \
        "jq . '$PAI_DIR/settings.json' > /dev/null 2>&1"

    validate "CLAUDE.md exists" \
        "[[ -f '$PAI_DIR/CLAUDE.md' ]]"

    NEW_VERSION=$(jq -r '.version // "unknown"' "$PAI_DIR/settings.json")
    validate "Version updated to $NEW_VERSION" \
        "[[ '$NEW_VERSION' == '${TARGET_VERSION#v}' ]]"

    validate "PAI/Algorithm/LATEST exists" \
        "[[ -f '$PAI_DIR/PAI/Algorithm/LATEST' ]]"

    validate "PAI/USER/ directory intact" \
        "[[ -d '$PAI_DIR/PAI/USER' ]]"

    validate "MEMORY/ directory intact" \
        "[[ -d '$PAI_DIR/MEMORY' ]]"

    validate "hooks/ has .ts files" \
        "[[ \$(find '$PAI_DIR/hooks' -name '*.ts' -type f 2>/dev/null | wc -l) -gt 0 ]]"

    validate "skills/ has SKILL.md files" \
        "[[ \$(find '$PAI_DIR/skills' -name 'SKILL.md' -type f 2>/dev/null | wc -l) -gt 0 ]]"

    validate "CLAUDE.md.template exists" \
        "[[ -f '$PAI_DIR/CLAUDE.md.template' ]]"

    validate "Auto-memory directory intact" \
        "[[ -d '$PAI_DIR/projects' ]]"

    echo ""
    if [[ "$FAIL" -eq 0 ]]; then
        log "All $TOTAL validation checks passed"
    else
        err "$FAIL/$TOTAL checks failed"
    fi
fi

# ─── Phase 9: Report ────────────────────────────────────────────────

header "Phase 9: Upgrade Report"

if $DRY_RUN; then
    echo -e "${BOLD}DRY RUN COMPLETE — no changes were made${NC}"
    echo ""
    info "Would upgrade: PAI v${CURRENT_VERSION} → ${TARGET_VERSION#v}"
else
    echo -e "${BOLD}PAI Upgrade Complete${NC}"
    echo ""
    echo -e "  ${CYAN}Version:${NC}    v${CURRENT_VERSION} → v${NEW_VERSION}"
    echo -e "  ${CYAN}Algorithm:${NC}  v${CURRENT_ALGO} → v$(jq -r '.algorithmVersion // "unknown"' "$PAI_DIR/settings.json")"
    echo ""
    echo -e "  ${GREEN}Preserved:${NC}"
    echo -e "    MEMORY/         $(du -sh "$PAI_DIR/MEMORY" 2>/dev/null | cut -f1) ($(find "$PAI_DIR/MEMORY" -type f 2>/dev/null | wc -l) files)"
    echo -e "    PAI/USER/       $(du -sh "$PAI_DIR/PAI/USER" 2>/dev/null | cut -f1) ($(find "$PAI_DIR/PAI/USER" -type f 2>/dev/null | wc -l) files)"
    echo -e "    settings.json   $(du -sh "$PAI_DIR/settings.json" 2>/dev/null | cut -f1) (custom config merged)"
    echo -e "    Auto-memory     $(du -sh "$PAI_DIR/projects" 2>/dev/null | cut -f1) (Claude Code memory)"
    echo ""
    echo -e "  ${BLUE}Updated:${NC}"
    echo -e "    PAI/ system     docs, tools, algorithm, components"
    echo -e "    hooks/          $(find "$PAI_DIR/hooks" -name '*.ts' -type f 2>/dev/null | wc -l) hook files"
    echo -e "    skills/         $(find "$PAI_DIR/skills" -name 'SKILL.md' -type f 2>/dev/null | wc -l) skills"
    echo -e "    CLAUDE.md       regenerated from template"
    echo ""
    if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
        echo -e "  ${YELLOW}Backup:${NC}     $BACKUP_DIR"
        echo -e "              Rollback: ${BOLD}rm -rf ~/.claude && mv $BACKUP_DIR ~/.claude${NC}"
    fi
    echo ""
    log "Run 'source ~/.zshrc && pai' to test the upgrade"
fi
