cat > setup_autovnc.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
# sudo VNC_PASS='strongpass' DESKTOP=lxde bash setup_autovnc.sh
# DESKTOP can be xfce (default) or lxde

: "${VNC_PASS:=mrprayoger}"
: "${DESKTOP:=xfce}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo: sudo VNC_PASS='...' DESKTOP=xfce bash setup_autovnc.sh"
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive

echo "Installing desktop: $DESKTOP  and VNC/noVNC… 🚀"
apt-get update -qq
if [ "$DESKTOP" = "lxde" ]; then
  apt-get install -y --no-install-recommends lxde-core lxterminal x11-xserver-utils dbus-x11
else
  apt-get install -y --no-install-recommends xfce4 xfce4-terminal xfce4-goodies dbus-x11
fi

apt-get install -y --no-install-recommends tigervnc-standalone-server tigervnc-common novnc websockify wget python3-websockify || true

# Create user info (target the original non-root sudo user if available)
VNCUSER="${SUDO_USER:-$(logname 2>/dev/null || root)}"
USERHOME=$(eval echo "~$VNCUSER")

echo "Using VNC user: $VNCUSER ($USERHOME)"

mkdir -p "$USERHOME/.vnc"
chown -R "$VNCUSER":"$VNCUSER" "$USERHOME/.vnc"

# Create VNC password non-interactively
echo "Setting VNC password (hidden)..."
printf "%s\n%s\n\n" "$VNC_PASS" "$VNC_PASS" | su - "$VNCUSER" -c 'vncpasswd -f > ~/.vnc/passwd'
chmod 600 "$USERHOME/.vnc/passwd"
chown "$VNCUSER":"$VNCUSER" "$USERHOME/.vnc/passwd"

# Write xstartup based on desktop choice
cat > "$USERHOME/.vnc/xstartup" <<'XSTART'
#!/bin/sh
xrdb $HOME/.Xresources || true
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
  eval "$(dbus-launch --sh-syntax --exit-with-session || true)"
fi
XSTART

if [ "$DESKTOP" = "lxde" ]; then
  cat >> "$USERHOME/.vnc/xstartup" <<'XEND'
# start lxde
startlxde &
XEND
else
  cat >> "$USERHOME/.vnc/xstartup" <<'XEND'
# start xfce
startxfce4 &
XEND
fi

chmod +x "$USERHOME/.vnc/xstartup"
chown "$VNCUSER":"$VNCUSER" "$USERHOME/.vnc/xstartup"

# Kill any existing :1, then start vncserver :1
echo "Restarting vncserver :1..."
su - "$VNCUSER" -c 'vncserver -kill :1 >/dev/null 2>&1 || true'
su - "$VNCUSER" -c 'vncserver :1 -geometry 1080x720 -depth 24'

# Ensure noVNC web files exist; if not, download minimal copy
NOVNC_WEB="/usr/share/novnc"
if [ ! -d "$NOVNC_WEB" ]; then
  echo "noVNC not packaged — downloading a copy..."
  tmpd=$(mktemp -d)
  wget -qO- https://github.com/novnc/noVNC/archive/refs/heads/master.tar.gz | tar xz -C "$tmpd"
  NOVNC_WEB="$tmpd/noVNC-master"
fi

# Start websockify (noVNC) on port 6080 -> localhost:5901
echo "Starting noVNC (websockify) on port 6080 -> localhost:5901..."
nohup websockify --web="$NOVNC_WEB" --heartbeat=30 6080 localhost:5901 > /var/log/novnc-websockify.log 2>&1 &

sleep 1

# Create a tiny autostart helper in user's home to restart services automatically in future shells
AUTOSTART="$USERHOME/.start_codespace_vnc.sh"
cat > "$AUTOSTART" <<'AUTO'
#!/usr/bin/env bash
# Simple helper to ensure VNC and noVNC are running. Safe to call multiple times.

# start vncserver if not running
if ! pgrep -f "Xtigervnc .*:1" >/dev/null 2>&1; then
  su - "$SUDO_USER" -c 'vncserver :1 -geometry 1080x720 -depth 24' 2>/dev/null || true
fi

# start websockify if not running
if ! pgrep -f "websockify .*6080" >/dev/null 2>&1; then
  nohup websockify --web="$NOVNC_WEB" --heartbeat=30 6080 localhost:5901 > /var/log/novnc-websockify.log 2>&1 &
fi
AUTO

# Replace placeholders and set perms
sed -i "s|\\$NOVNC_WEB|$NOVNC_WEB|g" "$AUTOSTART" || true
chown "$VNCUSER":"$VNCUSER" "$AUTOSTART"
chmod +x "$AUTOSTART"

# Add autostart call to user's bashrc if not already present
BASHRC="$USERHOME/.bashrc"
if ! grep -Fq ".start_codespace_vnc.sh" "$BASHRC" 2>/dev/null; then
  echo "" >> "$BASHRC"
  echo "# auto-start VNC/noVNC for Codespaces" >> "$BASHRC"
  echo "[ -x \"$AUTOSTART\" ] && \"$AUTOSTART\" >/dev/null 2>&1 || true" >> "$BASHRC"
  chown "$VNCUSER":"$VNCUSER" "$BASHRC"
fi

# Attempt to detect exact public app.github.dev domain
# Codespaces sets CODESPACE_NAME in many environments; use it if available
CODESPACE_NAME="${CODESPACE_NAME:-${GITHUB_CODESPACE_NAME:-}}"

if [ -n "$CODESPACE_NAME" ]; then
  PUBLIC_BASE="$CODESPACE_NAME"
  PUBLIC_URL="https://${PUBLIC_BASE}-6080.app.github.dev/"
else
  # Try to guess from known preview envs (fallback)
  # If the user has previously opened a forwarded URL, it often contains a prefix like "glowing-guacamole-xxxx"
  # We can't always know it; provide explicit instructions instead.
  PUBLIC_URL="https://<your-codespace-id>-6080.app.github.dev/   (see Codespaces PORTS panel to get exact host)"
fi

echo ""
echo "===== SETUP COMPLETE ✅ ====="
echo "VNC (internal) : display :1 -> TCP 5901 (internal to container)"
echo "noVNC (browser) : port 6080 (internal)"
echo ""
echo "Important next step: In Codespaces UI → PORTS → locate port 6080 → click the lock and make it PUBLIC."
echo ""
echo "Exact browser link to open:"
echo "  $PUBLIC_URL"
echo ""
echo "VNC password (user $VNCUSER): (hidden)  — you set it to the value of VNC_PASS."
echo "If you used the default, VNC_PASS=mrprayoger"
echo ""
echo "Logs: /var/log/novnc-websockify.log"
echo "To stop: su - $VNCUSER -c 'vncserver -kill :1' ; pkill -f websockify || true"
echo "To change password: su - $VNCUSER -c 'vncpasswd'"
echo "Autostart helper created at: $AUTOSTART (also called from ~/.bashrc)"
echo "=============================="
EOF
chmod +x setup_autovnc.sh
echo "Saved to setup_autovnc.sh — run with sudo, e.g.:"
echo "sudo VNC_PASS='myStrongPass' DESKTOP=xfce bash setup_autovnc.sh"