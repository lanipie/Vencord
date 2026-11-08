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

UPSTREAM_REMOTE="upstream"
UPSTREAM_BRANCH="main"

FORK_REMOTE="origin"
FORK_BRANCH="main"

CHECK_INTERVAL=1800
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

for command in git flock notify-send awk xargs; do
    command -v "$command" >/dev/null 2>&1 ||
        die "Required command not found: $command"
done

exec 9>"$LOCK"
flock -n 9 || exit 0

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

git -C "$REPO" remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 ||
    die "Git remote '$UPSTREAM_REMOTE' is missing."

git -C "$REPO" remote get-url "$FORK_REMOTE" >/dev/null 2>&1 ||
    die "Git remote '$FORK_REMOTE' is missing."

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
        line="${line%%#*}"
        [[ "$line" =~ [^[:space:]] ]] || continue

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

vesktop_pids() {
    local proc executable cmdline

    for proc in /proc/[0-9]*; do
        [[ -r "$proc/cmdline" && -e "$proc/exe" ]] || continue

        executable=$(readlink -f "$proc/exe" 2>/dev/null) || continue
        [[ "$executable" == "$VESKTOP_EXE" ]] || continue

        cmdline=$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null) || continue
        [[ "$cmdline" == *"--type="* ]] && continue

        printf '%s\n' "${proc##*/}"
    done
}

vesktop_running() {
    [[ -n "$(vesktop_pids)" ]]
}

close_vesktop() {
    local pid elapsed

    log "Requesting graceful Vesktop shutdown."

    while read -r pid; do
        [[ -n "$pid" ]] || continue
        log "Sending SIGINT to Vesktop main process $pid."
        kill -INT "$pid" 2>/dev/null || true
    done < <(vesktop_pids)

    for ((elapsed = 0; elapsed < VESKTOP_CLOSE_TIMEOUT; elapsed++)); do
        if ! vesktop_running; then
            log "Vesktop main process exited successfully."
            return 0
        fi
        sleep 1
    done

    log "ERROR: Vesktop did not exit within ${VESKTOP_CLOSE_TIMEOUT} seconds."
    return 1
}

launch_vesktop() {
    local elapsed

    log "Starting Vesktop."

    systemd-run \
        --user \
        --unit=vencord-vesktop-relaunch \
        --collect \
        --quiet \
        --no-block \
        "$VESKTOP_EXE" --disable-hdr || {
            log "ERROR: Could not start the Vesktop launcher."
            return 1
        }

    for ((elapsed = 0; elapsed < 20; elapsed++)); do
        if vesktop_running; then
            log "Vesktop main process detected. Relaunch successful."
            return 0
        fi
        sleep 1
    done

    log "ERROR: Vesktop did not start within 20 seconds."
    return 1
}

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
# Vencord repository validation
# ============================================================

validate_vencord_checkout() {
    local current

    current="$(git -C "$REPO" branch --show-current)"

    [[ "$current" == "main" ]] || {
        fail "Vencord is on branch '$current', not main."
        return 1
    }

    if [[ -n "$(git -C "$REPO" status --porcelain --untracked-files=no)" ]]; then
        fail "Vencord has tracked local changes. Commit or discard them before updating."
        return 1
    fi

    if [[ -n "$(git -C "$REPO" rev-parse --verify MERGE_HEAD 2>/dev/null || true)" ]]; then
        fail "Vencord has an unfinished Git merge. Resolve or abort it before updating."
        return 1
    fi
}

fetch_vencord_remotes() {
    log "Fetching official Vencord from upstream."

    git -C "$REPO" fetch --prune "$UPSTREAM_REMOTE" || {
        fail "Could not fetch official Vencord."
        return 1
    }

    log "Fetching personal fork from origin."

    git -C "$REPO" fetch --prune "$FORK_REMOTE" || {
        fail "Could not fetch personal fork."
        return 1
    }

    git -C "$REPO" show-ref --verify --quiet \
        "refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" || {
        fail "Official upstream/main does not exist."
        return 1
    }

    git -C "$REPO" show-ref --verify --quiet \
        "refs/remotes/$FORK_REMOTE/$FORK_BRANCH" || {
        fail "Personal origin/main does not exist."
        return 1
    }
}

# Merge a remote branch without rewriting history.
# Conflicts are aborted so the repository is not left mid-merge.
merge_remote_branch() {
    local remote_branch="$1"
    local description="$2"

    if git -C "$REPO" merge-base --is-ancestor "$remote_branch" HEAD; then
        log "$description is already included in local main."
        return 0
    fi

    log "Integrating $description."

    if git -C "$REPO" merge-base --is-ancestor HEAD "$remote_branch"; then
        git -C "$REPO" merge --ff-only "$remote_branch" || {
            fail "Could not fast-forward to $description."
            return 1
        }
    else
        if ! git -C "$REPO" merge --no-edit "$remote_branch"; then
            log "Merge conflict while integrating $description; aborting merge."
            git -C "$REPO" merge --abort >/dev/null 2>&1 || true
            fail "Could not merge $description. No force-push was attempted."
            return 1
        fi
    fi
}

# ============================================================
# Check repositories for updates
# ============================================================

check_for_updates() {
    local now last path url name branch current
    local found=no
    local i
    local upstream_ref fork_ref

    load_plugins || return 1
    validate_vencord_checkout || return 1

    now="$(date +%s)"
    last="$(cat "$LAST_ATTEMPT" 2>/dev/null || printf '0')"

    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    if ((now >= last && now - last < CHECK_INTERVAL)); then
        printf 'no\n'
        return 0
    fi

    printf '%s\n' "$now" >"$LAST_ATTEMPT"

    log "Checking official upstream and personal fork."

    fetch_vencord_remotes || return 1

    upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
    fork_ref="$FORK_REMOTE/$FORK_BRANCH"

    # Official commits not yet integrated into local main.
    if ! git -C "$REPO" merge-base --is-ancestor "$upstream_ref" HEAD; then
        found=yes
        log "Official Vencord has commits not yet integrated."
    fi

    # Personal fork commits not yet integrated locally.
    if ! git -C "$REPO" merge-base --is-ancestor "$fork_ref" HEAD; then
        found=yes
        log "Personal fork has commits not yet integrated locally."
    fi

    # Local commits not yet published to the personal fork.
    if [[ "$(git -C "$REPO" rev-list --count "$fork_ref..HEAD")" -gt 0 ]]; then
        found=yes
        log "Local main has commits not yet pushed to the personal fork."
    fi

    # Check configured plugins.
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
            if git -C "$path" merge-base --is-ancestor HEAD "origin/$branch"; then
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
    validate_vencord_checkout || return 1

    fetch_vencord_remotes || return 1

    # Validate installed plugins before changing repositories.
    for i in "${!PLUGIN_URLS[@]}"; do
        url="${PLUGIN_URLS[$i]}"
        name="${PLUGIN_NAMES[$i]}"
        path="$REPO/src/userplugins/$name"

        [[ -e "$path" ]] || continue

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

        if ! git -C "$path" merge-base --is-ancestor HEAD "origin/$branch"; then
            if [[ "$(git -C "$path" rev-parse HEAD)" != "$(git -C "$path" rev-parse "origin/$branch")" ]]; then
                fail "Plugin $name cannot be updated with a fast-forward."
                return 1
            fi
        fi
    done

    # Integrate commits already present on your personal fork.
    merge_remote_branch \
        "$FORK_REMOTE/$FORK_BRANCH" \
        "$FORK_REMOTE/$FORK_BRANCH" || return 1

    # Integrate the latest official Vencord commits.
    merge_remote_branch \
        "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" \
        "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" || return 1

    # Publish the synchronised branch to your personal fork.
    # Never force-push.
    log "Pushing synchronised main to personal fork."

    git -C "$REPO" push "$FORK_REMOTE" "main:$FORK_BRANCH" || {
        fail "Could not push synchronised main to personal fork."
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

    # Build Vencord.
    cd "$REPO"

    log "Building Vencord."

    "$PNPM" build || {
        fail "Vencord build failed."
        return 1
    }

    log "Update, fork synchronisation, and build completed successfully."
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
            --action=do="Do it" \
            --action=later=Later \
            "Vencord updates available" \
            "Official Vencord or a configured plugin has updates. Choose Do it to close Vesktop, synchronise, update and build, or Later to wait until Vesktop is closed."
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
                "Official Vencord, your fork, and configured plugins were synchronised and Vencord was built."
        else
            write_pending "undecided"
            notify-send \
                --app-name="Vencord Update Manager" \
                --urgency=normal \
                "Vencord update failed" \
                "The update, fork synchronisation, or build failed. Check the manager log before retrying."
        fi
        ;;

    do)
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
                "The update, fork synchronisation, or build failed. Check the manager log before retrying."
        fi
        ;;

    undecided)
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
