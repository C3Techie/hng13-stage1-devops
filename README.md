# HNG Stage 1 DevOps — Automated Deployment Script

This repository contains a single-file, production-grade Bash script that automates deploying a Dockerized application to a remote Linux server and configures Nginx as a reverse proxy.

It implements the full Stage 1 requirements: prompts/flags, secure cloning with PAT, remote setup, Docker/Compose deployment, Nginx proxy, validation, logging, idempotency, and an optional cleanup.

## What it does
- Collects inputs (repo URL, PAT, branch, SSH user/host/key, app port)
- Securely clones/pulls the repo locally using your PAT
- Verifies Dockerfile or docker-compose.yml exists
- Connects to your remote server via SSH and prepares the host (Docker, Compose, Nginx)
- Syncs project files and deploys containers (compose preferred, fallback to Dockerfile)
- Configures Nginx to proxy HTTP (80) to your app port
- Validates Docker, container health, and Nginx proxy
- Logs everything to `./logs/deploy_YYYYMMDD-HHMMSS.log`
- Idempotent and safe to re-run; includes `--cleanup` to remove resources

## Prerequisites
- A remote Linux server you can SSH into (Ubuntu/Debian/CentOS/RHEL/SUSE supported)
- An SSH private key on your local machine with access to the server
- A GitHub Personal Access Token (PAT) with repo read access
- Your repository must contain either a `Dockerfile` or a Compose file (`docker-compose.yml`/`compose.yml`)
- Port 80 open on the remote server firewall/security group (for Nginx)

## Usage
Make the script executable and run it. On Windows Git Bash, run in a bash shell.

```bash
chmod +x ./deploy.sh
./deploy.sh \
  --repo-url https://github.com/username/repo.git \
  --pat YOUR_GITHUB_PAT \
  --branch main \
  --ssh-user ubuntu \
  --ssh-host 203.0.113.10 \
  --ssh-key ~/.ssh/id_rsa \
  --app-port 3000
```

If you omit flags, the script will interactively prompt for values (except when `--non-interactive` is provided).

### Optional flags
- `--ssh-port 22` — set a custom SSH port
- `--project-name myapp` — override the inferred project name (defaults to repo name)
- `--remote-dir /opt/apps/myapp` — override the remote deployment directory
- `--non-interactive` — fail if required inputs are missing instead of prompting
- `--cleanup` — remove containers, images, Nginx config, and remote files for the project

Cleanup example:
```bash
./deploy.sh --cleanup \
  --ssh-user ubuntu --ssh-host 203.0.113.10 --ssh-key ~/.ssh/id_rsa \
  --project-name repo --remote-dir /opt/apps/repo
```

## Notes
- The script prefers `docker compose` (plugin). If not available, it falls back to `docker-compose` or a pure Dockerfile build/run.
- Nginx config uses `sites-available/sites-enabled` when present, else `/etc/nginx/conf.d/*.conf`.
- SSL is not enabled by default. Add Certbot or self-signed certs later as needed.

## Troubleshooting
- Check the log file in `./logs/` for detailed errors.
- Ensure your SSH key has correct permissions and server allows your user.
- Open port 80 on the server firewall/security group.
- Confirm your PAT is valid and has appropriate access to the repository.

## Submission
- Commit and push `deploy.sh` and this `README.md` to your GitHub repo.
- Verify you can access the app via `http://<server-ip>/`.
- Follow the HNG Slack submission instructions.

---
Built with care for reliability and re-runs. Good luck! 🚀