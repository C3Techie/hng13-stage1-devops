# HNG Stage 1 DevOps — Automated Deployment Script

This repository contains a single-file, production-grade Bash script that automates deploying a Dockerized application to a remote Linux server and configures Nginx as a reverse proxy.

It implements the full Stage 1 requirements: interactive input, secure cloning with a PAT, remote setup, Docker/Compose deployment, Nginx proxy, validation, logging, idempotency, and an optional cleanup mode.

---

## ✅ What the script does
- Prompts for all required inputs (repo URL, PAT, branch, SSH user/host/key, app port)
- Securely clones the GitHub repo locally using a Personal Access Token (PAT)
- Verifies `Dockerfile` or `docker-compose.yml` exists in the repo
- Connects to your remote Linux server via SSH and installs Docker, Compose, Nginx, rsync
- Transfers project files and deploys Docker containers
- Configures Nginx as a reverse proxy to your app
- Validates container and proxy status
- Logs all output to `./deploy_YYYYMMDD_HHMMSS.log`
- Safe to re-run (idempotent)
- Optional cleanup with `--cleanup` to remove app, containers, and config

---

## 📦 Prerequisites

- A remote Linux server with SSH access (Ubuntu/Debian/CentOS/RHEL/SUSE supported)
- SSH private key with access to the server
- A GitHub Personal Access Token (PAT) with repo read access
- Your repository must contain either:
  - A `Dockerfile`, or
  - A Compose file (`docker-compose.yml` or `docker-compose.yaml`)
- Port 80 must be open on the server's firewall or security group

---

## 🚀 Usage

Make the script executable and run it:

```bash
chmod +x ./deploy.sh
./deploy.sh
```

You will be prompted interactively to enter:

- Git repository URL
- Personal Access Token (PAT)
- Branch name (default: `main`)
- SSH username
- Server IP address
- Path to SSH private key (default: `~/.ssh/id_rsa`)
- Application port (e.g. `3000`)

The script will handle the rest — cloning the repo, setting up the server, deploying the app, and configuring Nginx.

---

## 🧹 Cleanup Mode

To remove a previous deployment (containers, images, files, and Nginx config), run:

```bash
./deploy.sh --cleanup
```

You will be prompted for:

- SSH username
- Server IP
- SSH key path
- Repository name (used to identify containers and directories)

---

## 📝 Notes

- The script prefers `docker compose` (plugin). If unavailable, it falls back to `docker-compose`, or to `Dockerfile`-based deployment.
- Nginx configuration is written to `/etc/nginx/sites-available/` and symlinked into `/etc/nginx/sites-enabled/`.
- SSL is not enabled by default. You can add HTTPS later using Certbot or self-signed certificates.
- The deployed app should be accessible at:  
  `http://<your-server-ip>/`

---

## 🧪 Troubleshooting

- Check the generated log file (e.g. `deploy_20251021_153000.log`) for errors.
- Ensure your SSH key has correct permissions and access.
- Confirm your PAT is valid and has permission to access the repository.
- Make sure the server allows traffic on port 80 (check firewall or cloud security group).
- Validate that the app runs correctly locally in Docker/Compose before deploying.

---

## 📤 Submission

- Commit and push both `deploy.sh` and this updated `README.md` to your GitHub repository.
- Test that your application is reachable via `http://<your-server-ip>/`.
- Follow the HNGiX Stage 1 submission guidelines on Slack.

---

Built for reliability, safe re-runs, and production-level simplicity.  
Happy shipping! 🚀
```
