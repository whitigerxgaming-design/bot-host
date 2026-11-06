<div align="center">

# ⚡ BotPanel

**Self-hosted bot hosting panel for your VPS.**
Host Python and Node.js bots with a clean web UI, live console, file manager, and a free random HTTPS link, all from one command.

![Platform](https://img.shields.io/badge/platform-Ubuntu%20%7C%20Debian-orange)
![Runtimes](https://img.shields.io/badge/runtimes-Python%20%7C%20Node.js-green)

</div>

---

## ✨ Features

| | |
|---|---|
| 🐍 **Python, Node.js, Custom** | Create bots in any runtime, with starter code included |
| 🖥️ **Live console** | Watch your bot's output in real time |
| 📁 **File manager** | Built-in code editor, upload, download, unzip, new file/folder |
| 🔁 **Auto-restart** | Bots restart if they crash and start again after a reboot |
| 🌐 **Free public URL** | Get a `random-words.trycloudflare.com` HTTPS link, no domain needed |
| 📊 **Resource stats** | Live CPU, RAM and disk usage per bot and for the server |
| 📦 **One-click dependencies** | Runs `pip install -r requirements.txt` or `npm install` for you |
| 💾 **No storage quotas** | Bots can use all free disk space on your VPS |
| 🔐 **Secure login** | Hashed password, login rate-limiting, change password in the UI |
| ⚙️ **systemd services** | Survives reboots, easy to manage |

---

## 📋 Requirements

- A VPS with **root** access
- **Ubuntu 20.04+** or **Debian 11+**
- **512 MB RAM** minimum (1 GB+ recommended)
- Internet access (the installer downloads packages and Cloudflare Tunnel)

---

## 🚀 Install

```bash
apt update && apt install -y git
git clone https://github.com/whitigerxgaming-design/bot-host.git
cd bot-host
chmod +x install.sh
sudo ./install.sh
```

Prefer a single line?

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/whitigerxgaming-design/bot-host/main/install.sh)
```

### What the installer asks

1. **What will you host?**: Python, Node.js / JavaScript, or both
2. **How to open the panel?**: free random Cloudflare URL, or direct `IP:port`
3. **Panel port** (default `8080`)
4. **Admin username and password** (leave the password empty to auto-generate one)

When it finishes, it prints your panel URL and login. They are also saved to `/root/botpanel-credentials.txt`.

---

## 🧭 Using the panel

1. Open the URL the installer printed and log in.
2. Click **＋ New bot**, pick a runtime and give it a name.
3. Open **Files** and upload your bot (a `.zip` works, then press **Unzip**).
4. Press **📦 Install dependencies** in the **Console** tab.
5. Set the **start command** in **Settings** if needed (for example `python3 bot.py` or `node app.js`).
6. Press **▶ Start**, then watch the console.

---

## 🛠️ Management

```bash
systemctl status botpanel          # panel status
systemctl restart botpanel         # restart panel (bots keep running)
systemctl status botpanel-tunnel   # tunnel status
journalctl -u botpanel -n 50       # panel logs
grep trycloudflare /opt/botpanel/data/tunnel.log   # find your public URL
```

Files live in `/opt/botpanel`. Bot files are in `/opt/botpanel/data/bots/<id>/files`.

### Uninstall

```bash
sudo ./install.sh --uninstall
```

This removes the panel **and all bot files**.

### Update

Pull the latest version and run the installer again. Your existing bots are kept.

```bash
cd bot-host && git pull && sudo ./install.sh
```

---

## ❓ FAQ

**Is storage really unlimited?**
There are no quotas, so bots can use all the free disk on your VPS. The limit is the size of your server's disk.

**Can I choose my own `.trycloudflare.com` name?**
No. Cloudflare picks the random words. For a fixed address, use a Cloudflare named tunnel with your own domain.

**My public URL changed. Why?**
Free quick tunnels get a new URL whenever the tunnel restarts or the VPS reboots. Run the `grep trycloudflare` command above, or check the top of the panel.

**Is this the same as Pterodactyl?**
No. BotPanel is a lightweight panel for bots. It has no multi-user accounts, nodes or eggs.

**Can I use it without Cloudflare?**
Yes. Choose option 2 during install and open `http://SERVER-IP:PORT`. Make sure the port is allowed in your firewall or cloud provider settings.

---

## 🩹 Troubleshooting

| Problem | Fix |
|---|---|
| `bad interpreter` or `\r` errors | The file has Windows line endings. Run `sed -i 's/\r$//' install.sh` |
| Panel won't open (direct mode) | Open the port in your firewall and your provider's security group |
| URL not shown after install | Wait 30 seconds, then run the `grep trycloudflare` command |
| Bot stops right after starting | Check the console for errors, and run **Install dependencies** |
| Python bot can't find a module | Add it to `requirements.txt`, then press **Install dependencies** |
| Forgot the password | See `/root/botpanel-credentials.txt`, or re-run `sudo ./install.sh` to set a new one |

---

## 🔒 Security notes

- The installer runs as **root**. Read `install.sh` before running it.
- Bots run as the same `botpanel` system user and are **not sandboxed**. Only host code you trust.
- Use a strong admin password, and change it from the panel header.
- Free Cloudflare quick tunnels are meant for testing and have no uptime guarantee.

---

## 🤝 Contributing

Issues and pull requests are welcome. If you find a bug, please include your OS version and the output of `journalctl -u botpanel -n 50`.
