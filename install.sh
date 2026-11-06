cd ~/bot-host 2>/dev/null || cd ~/ptero-installer
python3 - <<'EOF'
s=open('install.sh').read()
a=s.index('ask() {')
b=s.index('[ "$(id -u)" -eq 0 ]')
new='''ask() {            # ask "prompt" "default"  -> $REPLY
  local a=""
  printf '%b' "$1" >/dev/tty 2>/dev/null || true
  read -r a </dev/tty 2>/dev/null || true
  REPLY="${a:-${2:-}}"
}
ask_secret() {     # ask_secret "prompt" -> $REPLY (hidden)
  local a=""
  printf '%b' "$1" >/dev/tty 2>/dev/null || true
  read -rs a </dev/tty 2>/dev/null || true
  printf '\\n' >/dev/tty 2>/dev/null || true
  REPLY="$a"
}

'''
s=s[:a]+new+s[b:]
s=s.replace('-ge 1 ] && [ "$PORT" -le 65535 ] || die "Invalid port."','-ge 1024 ] && [ "$PORT" -le 65535 ] || die "Port must be a number from 1024 to 65535."')
open('install.sh','w').write(s)
EOF
sudo ./install.sh
