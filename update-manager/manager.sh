#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Configuration
# ============================================================

REPO="$HOME/git/Vencord"
PLUGIN_FILE="$REPO/update-manager/plugins.conf"
STATE="$HOME/.local/state/vencord-update-manager"

PENDING="$STATE/pending"
LAST_ATTEMPT="$STATE/last-attempt"
LOG="$STATE/manager.log"
LOCK="$STATE/manager.lock"

VESKTOP_EXE="/usr/lib/vesktop/vesktop"
VESKTOP_LAUNCHER="/usr/bin/vesktop"

PNPM="$HOME/.local/share/pnpm/bin/pnpm"

# Check Git remotes at most once every 30 minutes.
CHECK_INTERVAL=1800

# How long to wait for Vesktop to close after SIGTERM.
VESKTOP_CLOSE_TIMEOUT=30

# ============================================================
# Initial setup and logging
# ============================================================

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

mkdir -p "$STATE"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"
}

fail() {
    log "ERROR: $*"
    return 1
}

# Check dependencies before using flock.
for command in git flock notify-send awk xargs; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

# Prevent overlapping manager instances.
exec 9>"$LOCK"
flock -n 9 || exit 0

# Validate the installation.
[[ -d "$REPO/.git" ]] ||
    die "Vencord checkout not found at $REPO"

[[ -f "$PLUGIN_FILE" ]] ||
    die "Missing plugin configuration: $PLUGIN_FILE"

[[ -x "$PNPM" ]] ||
    die "pnpm is not executable at $PNPM"

[[ -x "$VESKTOP_EXE" ]] ||
    die "Vesktop executable not found at $VESKTOP_EXE"

[[ -x "$VESKTOP_LAUNCHER" ]] ||
    die "Vesktop launcher not found at $VESKTOP_LAUNCHER"

command -v systemd-run >/dev/null 2>&1 ||
    die "systemd-run was not found."

# ============================================================
# Persistent state
# ============================================================

write_pending() {
    local value="$1"
    printf '%s\n' "$value" >"$PENDING.tmp"
    mv "$PENDING.tmp" "$PENDING"
}

# ============================================================
# Plugin configuration
# ============================================================

load_plugins() {
    PLUGIN_URLS=()
    PLUGIN_NAMES=()

    local line url name existing

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Ignore comments and blank lines.
        line="${line%%#*}"
        [[ "$line" =~ [^[:space:]] ]] || continue

        # Each entry must contain URL|directory.
        [[ "$line" == *"|"* ]] || {
            fail "Invalid plugin entry: $line"
            return 1
        }

        url="$(printf '%s' "${line%%|*}" | xargs)"
        name="$(printf '%s' "${line#*|}" | xargs)"

        [[ -n "$url" && -n "$name" ]] || {
            fail "Plugin URL or directory is empty."
            return 1
        }

        [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || {
            fail "Unsafe plugin directory name: $name"
            return 1
        }

        [[ "$url" =~ ^(https://|ssh://|git@) ]] || {
            fail "Unsupported plugin URL: $url"
            return 1
        }

        for existing in "${PLUGIN_NAMES[@]}"; do
            [[ "$existing" != "$name" ]] || {
                fail "Duplicate plugin directory: $name"
                return 1
            }
        done

        PLUGIN_URLS+=("$url")
        PLUGIN_NAMES+=("$name")

    done <"$PLUGIN_FILE"
}

# ============================================================
# Vesktop process detection and shutdown
# ============================================================

# Find only the main Vesktop process, not Electron helpers.
vesktop_pids() {
    local proc first

    for proc in /proc/[0-9]*; do
        [[ -r "$proc/cmdline" ]] || continue

        first=""
        IFS= read -r -d '' first <"$proc/cmdline" || true

        if [[ "$first" == "$VESKTOP_EXE" ]]; then
            printf '%s\n' "${proc##*/}"
        fi
    done
}

vesktop_running() {
    [[ -n "$(vesktop_pids)" ]]
}

# Request a normal shutdown and wait. Never force-kill Vesktop.
close_vesktop() {
    local pid elapsed

    log "Requesting graceful Vesktop shutdown."

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done < <(vesktop_pids)

    for ((elapsed = 0; elapsed < VESKTOP_CLOSE_TIMEOUT; elapsed++)); do
        if ! vesktop_running; then
            log "Vesktop closed successfully."
            return 0
        fi

        sleep 1
    done

    log "Vesktop did not close within ${VESKTOP_CLOSE_TIMEOUT} seconds."
    return 1
}

# Launch Vesktop in its own user systemd service so it survives
# the update-manager service exiting.
launch_vesktop() {
    log "Launching Vesktop."

    systemd-run \
        --user \
        --unit=vencord-vesktop-relaunch \
        --collect \
        --quiet \
        --no-block \
        "$VESKTOP_LAUNCHER"
}

# ============================================================
# Plugin default branch detection
# ============================================================

plugin_default_branch() {
    local path="$1"
    local symbolic

    git -C "$path" remote set-head origin -a \
        >/dev/null 2>&1 || true

    symbolic="$(
        git -C "$path" symbolic-ref \
            --quiet --short refs/remotes/origin/HEAD || true
    )"

    printf '%s' "${symbolic#origin/}"
}

# ============================================================
# Check repositories for updates
# ============================================================

# Prints "yes" or "no".
check_for_updates() {
    local now last path url name branch current
    local found=no
    local i

    load_plugins || return 1

    now="$(date +%s)"
    last="$(cat "$LAST_ATTEMPT" 2>/dev/null || printf '0')"

    # Treat invalid timestamps as zero.
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    # Throttle successful AND failed remote checks.
    if ((now >= last && now - last < CHECK_INTERVAL)); then
        printf 'no\n'
        return 0
    fi

    # Match the original upgrade.sh: switch to main before updating.
    git -C "$REPO" checkout main || {
        fail "Could not switch Vencord to main."
        return 1
    }

    # Permit the existing local upgrade.sh modification only.
    if ! git -C "$REPO" status --porcelain --untracked-files=no |
        awk '$2 != "upgrade.sh" { bad=1 } END { exit bad }'; then
        fail "Vencord has tracked local changes other than upgrade.sh."
        return 1
    fi

    if ! git -C "$REPO" diff --cached --quiet -- upgrade.sh; then
        fail "upgrade.sh has staged changes; unstage them before updating."
        return 1
    fi

    # Record the attempt before network operations.
    # This prevents repeated fetches when GitHub is unavailable.
    printf '%s\n' "$now" >"$LAST_ATTEMPT"

    log "Checking Vencord origin/main."

    git -C "$REPO" fetch --prune origin || {
        fail "Could not fetch Vencord origin."
        return 1
    }

    git -C "$REPO" show-ref --verify --quiet refs/remotes/origin/main || {
        fail "Vencord origin/main does not exist."
        return 1
    }

    # Any commits on origin/main that are not in HEAD mean an update is
    # available. Divergence is left to the same git pull strategy used by
    # the original upgrade.sh.
    if [[ "$(git -C "$REPO" rev-list --count HEAD..origin/main)" -gt 0 ]]; then
        found=yes
    fi

    # Check every configured plugin.
    for i in "${!PLUGIN_URLS[@]}"; do
        url="${PLUGIN_URLS[$i]}"
        name="${PLUGIN_NAMES[$i]}"
        path="$REPO/src/userplugins/$name"

        if [[ ! -e "$path" ]]; then
            log "Plugin $name is not installed."
            found=yes
            continue
        fi

        [[ -d "$path" ]] || {
            fail "Plugin path is not a directory: $path."
            return 1
        }

        git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || {
            fail "$path is not a Git repository."
            return 1
        }

        [[ "$(git -C "$path" remote get-url origin 2>/dev/null || true)" == "$url" ]] || {
            fail "Plugin $name origin does not match plugins.conf."
            return 1
        }

        [[ -z "$(git -C "$path" status --porcelain)" ]] || {
            fail "Plugin $name has local changes."
            return 1
        }

        log "Checking plugin $name."

        git -C "$path" fetch --prune origin || {
            fail "Could not fetch plugin $name."
            return 1
        }

        branch="$(plugin_default_branch "$path")"

        [[ -n "$branch" ]] || {
            fail "Cannot determine the default branch for plugin $name."
            return 1
        }

        current="$(git -C "$path" branch --show-current)"

        [[ "$current" == "$branch" ]] || {
            fail "Plugin $name is on $current, not its default branch $branch."
            return 1
        }

        if [[ "$(git -C "$path" rev-parse HEAD)" != "$(git -C "$path" rev-parse "origin/$branch")" ]]; then

            if git -C "$path" merge-base --is-ancestor \
                HEAD "origin/$branch"; then
                found=yes
            else
                fail "Plugin $name has diverged from origin/$branch."
                return 1
            fi
        fi
    done

    printf '%s\n' "$found"
}

# ============================================================
# Apply updates and build
# ============================================================

apply_updates() {
    local path url name branch
    local i

    load_plugins || return 1

    # Match the original upgrade.sh: switch to main before updating.
    git -C "$REPO" checkout main || {
        fail "Could not switch Vencord to main."
        return 1
    }

    if ! git -C "$REPO" status --porcelain --untracked-files=no |
        awk '$2 != "upgrade.sh" { bad=1 } END { exit bad }'; then
        fail "Vencord has tracked local changes."
        return 1
    fi

    if ! git -C "$REPO" diff --cached --quiet -- upgrade.sh; then
        fail "upgrade.sh has staged changes; unstage them before updating."
        return 1
    fi

    # Fetch Vencord.
    log "Fetching Vencord from origin."

    git -C "$REPO" fetch --prune origin || {
        fail "Could not fetch Vencord."
        return 1
    }

    # Fetch and validate every installed plugin before changing refs.
    for i in "${!PLUGIN_URLS[@]}"; do
        url="${PLUGIN_URLS[$i]}"
        name="${PLUGIN_NAMES[$i]}"
        path="$REPO/src/userplugins/$name"

        if [[ ! -e "$path" ]]; then
            continue
        fi

        [[ -d "$path" ]] || {
            fail "Plugin path is not a directory: $path."
            return 1
        }

        git -C "$path" rev-parse --git-dir >/dev/null 2>&1 || {
            fail "$path is not a Git repository."
            return 1
        }

        [[ "$(git -C "$path" remote get-url origin 2>/dev/null || true)" == "$url" ]] || {
            fail "Plugin $name origin does not match plugins.conf."
            return 1
        }

        [[ -z "$(git -C "$path" status --porcelain)" ]] || {
            fail "Plugin $name has local changes."
            return 1
        }

        git -C "$path" fetch --prune origin || {
            fail "Could not fetch plugin $name."
            return 1
        }

        branch="$(plugin_default_branch "$path")"

        [[ -n "$branch" ]] || {
            fail "Cannot determine the default branch for plugin $name."
            return 1
        }

        [[ "$(git -C "$path" branch --show-current)" == "$branch" ]] || {
            fail "Plugin $name is not on its default branch ($branch)."
            return 1
        }

        if ! git -C "$path" merge-base --is-ancestor \
            HEAD "origin/$branch"; then

            if [[ "$(git -C "$path" rev-parse HEAD)" != "$(git -C "$path" rev-parse "origin/$branch")" ]]; then
                fail "Plugin $name cannot be updated with a fast-forward."
                return 1
            fi
        fi
    done

    # All installed repositories passed validation.
    log "Updating Vencord."

    git -C "$REPO" pull origin main || {
        fail "Could not pull Vencord from origin/main."
        return 1
    }

    # Update or clone configured plugins.
    mkdir -p "$REPO/src/userplugins"

    for i in "${!PLUGIN_URLS[@]}"; do
        url="${PLUGIN_URLS[$i]}"
        name="${PLUGIN_NAMES[$i]}"
        path="$REPO/src/userplugins/$name"

        if [[ ! -e "$path" ]]; then
            log "Cloning plugin $name."

            git clone "$url" "$path" || {
                fail "Could not clone plugin $name."
                return 1
            }

            continue
        fi

        branch="$(plugin_default_branch "$path")"

        log "Updating plugin $name."

        git -C "$path" merge --ff-only "origin/$branch" || {
            fail "Could not fast-forward plugin $name."
            return 1
        }
    done

    # Build Vencord, as in the original upgrade.sh.
    cd "$REPO"

    log "Building Vencord."

    "$PNPM" build || {
        fail "Vencord build failed."
        return 1
    }

    log "Update and build completed successfully."
    return 0
}

# ============================================================
# Notification and user decision
# ============================================================

ask_user() {
    local action

    log "Waiting for update decision."

    action="$(
        notify-send \
            --app-name="Vencord Update Manager" \
            --urgency=normal \
            --wait \
            --action=do=Do it \
            --action=later=Later \
            "Vencord updates available" \
            "Updates are ready. Choose Do it to close Vesktop, update and build, or Later to wait until Vesktop is closed."
    )" || action=""

    case "$action" in
    do)
        write_pending "do"
        log "User selected Do it."
        ;;
    later)
        write_pending "later"
        log "User selected Later."
        ;;
    *)
        # No explicit choice: ask again on the next timer run.
        write_pending "undecided"
        log "No action selected; leaving decision undecided."
        ;;
    esac
}

# ============================================================
# Process a saved decision
# ============================================================

process_pending() {
    local decision

    decision="$(cat "$PENDING" 2>/dev/null || true)"

    case "$decision" in
    later)
        # Later means wait until Vesktop is closed naturally.
        if vesktop_running; then
            log "Update deferred; Vesktop is still running."
            return 0
        fi

        log "Vesktop is closed; processing deferred update."

        if apply_updates; then
            rm -f "$PENDING"
            notify-send \
                --app-name="Vencord Update Manager" \
                "Vencord update complete" \
                "Updates were installed and Vencord was built."
        else
            write_pending "undecided"
            notify-send \
                --app-name="Vencord Update Manager" \
                --urgency=normal \
                "Vencord update failed" \
                "The update or build failed. Check the manager log before retrying."
        fi
        ;;

    do)
        # Do it means close Vesktop gracefully, update, build,
        # then relaunch it.
        if vesktop_running && ! close_vesktop; then
            write_pending "do"

            notify-send \
                --app-name="Vencord Update Manager" \
                --urgency=normal \
                "Vesktop is still running" \
                "It did not close in time. The update has been deferred until Vesktop is closed."

            return 0
        fi

        if apply_updates; then
            rm -f "$PENDING"

            if launch_vesktop; then
                log "Vesktop relaunch requested."
            else
                log "ERROR: Update succeeded, but Vesktop could not be relaunched."

                notify-send \
                    --app-name="Vencord Update Manager" \
                    --urgency=normal \
                    "Vencord updated" \
                    "The build succeeded, but Vesktop could not be relaunched."
            fi
        else
            write_pending "undecided"

            notify-send \
                --app-name="Vencord Update Manager" \
                --urgency=normal \
                "Vencord update failed" \
                "The update or build failed. Check the manager log before retrying."
        fi
        ;;

    undecided)
        # Ask once, then process only an explicit choice.
        ask_user
        decision="$(cat "$PENDING" 2>/dev/null || true)"

        case "$decision" in
        do | later)
            process_pending
            ;;
        *)
            log "No decision made; waiting for the next timer run."
            ;;
        esac
        ;;

    *)
        log "No pending update decision."
        ;;
    esac
}

# ============================================================
# Main
# ============================================================

log "Manager started."

if [[ -s "$PENDING" ]]; then
    process_pending
    exit 0
fi

if ! updates="$(check_for_updates)"; then
    log "Update check failed. See earlier log entries."
    exit 0
fi

if [[ "$updates" == "yes" ]]; then
    log "Updates are available."
    write_pending "undecided"
    process_pending
else
    log "No updates found."
fi

exit 0
