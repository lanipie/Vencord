#!/usr/bin/env bash
set -Eeuo pipefail

REPO="$HOME/git/Vencord"
MANAGER="$REPO/update-manager"
SYSTEMD="$HOME/.config/systemd/user"
STATE="$HOME/.local/state/vencord-update-manager"

SERVICE="$SYSTEMD/vencord-update-manager.service"
TIMER="$SYSTEMD/vencord-update-manager.timer"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

echo "Checking Vencord Update Manager installation..."

# Verify the repository and manager files.
[[ -d "$REPO/.git" ]] ||
    die "Vencord Git checkout not found at $REPO"

[[ -f "$MANAGER/manager.sh" ]] ||
    die "Missing update-manager/manager.sh"

[[ -f "$MANAGER/plugins.conf" ]] ||
    die "Missing update-manager/plugins.conf"

# Check manager syntax before installing anything.
bash -n "$MANAGER/manager.sh" ||
    die "manager.sh contains a syntax error."

# Verify required commands.
for cmd in git systemctl notify-send flock awk xargs systemd-run; do
    command -v "$cmd" >/dev/null ||
        die "Required command not found: $cmd"
done

# Verify pnpm.
PNPM="$HOME/.local/share/pnpm/bin/pnpm"

if [[ ! -x "$PNPM" ]]; then
    PNPM="$(command -v pnpm || true)"
fi

[[ -n "$PNPM" && -x "$PNPM" ]] ||
    die "pnpm was not found."

# Verify Vesktop paths used by manager.sh.
[[ -x /usr/lib/vesktop/vesktop ]] ||
    die "Vesktop executable not found."

[[ -x /usr/bin/vesktop ]] ||
    die "Vesktop launcher not found."

# Prepare directories.
mkdir -p "$SYSTEMD" "$STATE"

# Preserve the original upgrade script if no backup exists.
if [[ -f "$REPO/upgrade.sh" &&
    ! -f "$STATE/backups/upgrade.sh.original" ]]; then
    mkdir -p "$STATE/backups"
    cp -p "$REPO/upgrade.sh" "$STATE/backups/upgrade.sh.original"
    echo "Preserved original upgrade.sh."
fi

# Make sure the manager is executable.
chmod 755 "$MANAGER/manager.sh"

# Install the systemd service.
cat >"$SERVICE" <<'SERVICE'
[Unit]
Description=Vencord Update Manager

[Service]
Type=oneshot
ExecStart=%h/git/Vencord/update-manager/manager.sh
TimeoutStartSec=infinity
SERVICE

# Install the periodic timer.
cat >"$TIMER" <<'TIMER'
[Unit]
Description=Periodic Vencord Update Check

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=vencord-update-manager.service

[Install]
WantedBy=timers.target
TIMER

# Register the new unit files.
systemctl --user daemon-reload

echo
echo "Installation files are ready."
echo
echo "Manager:           $MANAGER/manager.sh"
echo "Plugin list:       $MANAGER/plugins.conf"
echo "Plugin directory:  $REPO/src/userplugins/"
echo "State and logs:    $STATE/"
echo
echo "The timer will poll every 5 minutes."
echo "Git remote checks are limited to once every 30 minutes."
echo
echo "No update or build has been run."
echo

read -r -p "Enable and start the update timer now? [y/N] " answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    systemctl --user enable --now vencord-update-manager.timer
    echo
    echo "Vencord Update Manager timer enabled."
else
    echo
    echo "Timer not enabled."
    echo "To enable it later, run:"
    echo "systemctl --user enable --now vencord-update-manager.timer"
fi
