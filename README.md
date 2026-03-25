
# Facebook Blocker

Easily block or unblock Facebook on your computer with a simple Bash script.

## 🚀 Features

- **Block Facebook** instantly by modifying your `/etc/hosts` file.
- **Unblock Facebook** temporarily (removes the block entry).
- Simple command-line usage.
- Lightweight and easy to use.

## 🛠️ Usage

> **Requires root privileges** to modify `/etc/hosts`.

### Block Facebook

```bash
sudo ./block_fb.sh block
```

### Unblock Facebook

```bash
sudo ./block_fb.sh unblock
```

## 📄 How it works

- Adds or removes the following line in `/etc/hosts`:
	```
	127.0.0.1 www.facebook.com
	```
- Blocking prevents your browser from accessing Facebook.
- Unblocking removes the restriction.

## ⚠️ Disclaimer

- This script only blocks `www.facebook.com`. Other Facebook domains (like `facebook.com` or `m.facebook.com`) are not blocked by default.
- Use responsibly. Editing `/etc/hosts` affects all users on the system.

## 📝 License

MIT License
