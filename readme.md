# deploy

A tiny bash tool to deploy a project to a server with `rsync` over SSH and manage its Docker Compose containers, driven by a single `deploy.conf` per project.

- Syncs files with `rsync`, respecting `.gitignore` (including nested ones)
- One config file per project, picked up from the current directory
- Shared settings and custom command aliases in one `common.conf`
- Nothing restarts unless you ask for it
- Works with the stock macOS bash (3.2), no bash 4 features required

## Requirements

- `bash`
- `rsync`
- `ssh` access to the server (key-based auth recommended)
- Docker Compose v2 on the server (`docker compose ...`)

## Installation

```bash
git clone https://github.com/roma351/deploy.git ~/Scripts/deploy
chmod +x ~/Scripts/deploy/deploy.sh
```

Add an alias to your `~/.zshrc` or `~/.bashrc`:

```bash
alias deploy="~/Scripts/deploy/deploy.sh"
```

`common.conf` must stay next to `deploy.sh` (symlinks to the script are resolved, so the file is still found).

## Configuration

### `common.conf` (next to `deploy.sh`)

Shared by all projects:

```bash
REMOTE_HOST="deploy@server.example.com"
REMOTE_BASE="/srv/apps"
SSH_PORT=22
# SSH_KEY="$HOME/.ssh/id_ed25519"

# Custom aliases: `deploy <alias>` runs the returned command on the server
cmd_alias() {
  case "$1" in
    nginx-restart) echo "cd $REMOTE_BASE/infra && docker compose restart nginx" ;;
    ps)            echo "docker ps" ;;
    *) return 1 ;;
  esac
}
```

| Variable | Description |
|---|---|
| `REMOTE_HOST` | `user@host` used for ssh and rsync |
| `REMOTE_BASE` | Base directory for apps on the server (handy for building paths) |
| `SSH_PORT` | SSH port, default `22` |
| `SSH_KEY` | Optional path to a private key; omit to use your agent or default key |
| `cmd_alias()` | Optional function mapping an alias name to a shell command run on the server |

### `deploy.conf` (in each project)

Put this file in the root of the project you want to deploy:

```bash
REMOTE_DIR="$REMOTE_BASE/my-project"
```

That is all that is required. The local source is the directory you run `deploy` from, and the destination becomes `REMOTE_HOST:REMOTE_DIR/`.

Optional overrides: `SRC`, `DEST`, and any variable from `common.conf` (for example a different `REMOTE_HOST` for one project).

## Usage

Run commands from the project directory (the one that contains `deploy.conf`).

### Uploading files

```bash
deploy upload                # rsync project -> server
deploy upload dry            # preview what would change, nothing is transferred
deploy upload restart        # rsync, then `docker compose restart`
deploy upload up             # rsync, then `docker compose up -d --build`

deploy upload-env            # sync only .env.* files
deploy upload-env dry
deploy upload-env restart
deploy upload-env up
```

With `dry`, the follow-up `restart` / `up` is never executed.

### Managing containers

```bash
deploy up                    # docker compose up -d --build
deploy restart               # docker compose restart (all services)
deploy restart nginx         # restart a single service
deploy logs                  # docker compose logs -f --tail=100
deploy logs nginx            # logs of a single service
```

### Custom aliases

Anything defined in `cmd_alias()` in `common.conf` runs on the server over ssh:

```bash
deploy ps
deploy nginx-restart
```

## How file syncing works

### `upload`

```
rsync -avz --checksum --delete --progress \
  --exclude '.git' --include '.env.example' --filter=':- .gitignore'
```

- **`.gitignore` support.** `--filter=':- .gitignore'` makes rsync read a `.gitignore` in every directory it walks, not only the root one. You can point `deploy` at a parent folder that contains several sub-projects, each with its own `.gitignore`.
- **Ignored directories are not scanned.** If `node_modules/` or `venv/` is ignored, rsync does not descend into it.
- **Ignored files on the server are kept.** Files matching `.gitignore` are protected from `--delete`, so server-only files such as `.env`, databases or uploads are not removed.
- **`--delete`** removes files on the server that no longer exist locally (and are not ignored). Use `deploy upload dry` first if unsure.
- **`--checksum`** compares file contents instead of size and modification time, so unchanged files are skipped even if their timestamps differ.
- **Negation (`!`) is not supported.** rsync does not understand `!pattern` from `.gitignore`. The only exception that is handled explicitly is `.env.example`, so you can ignore `.env.*` and still ship `.env.example`.

### `upload-env`

Transfers only files named `.env.*` (for example `.env.prod`, `.env.local`), skipping `.git` and everything excluded by `.gitignore`. It never uses `--delete`.

The plain `.env` is not transferred. A common setup is to make `.env` a symlink to one of the `.env.*` files on each machine (`.env -> .env.prod` on the server, `.env -> .env.local` on your laptop), keep the code identical on both sides, and push env changes with `deploy upload-env`.

Make sure `.env` and `.env.*` are in your `.gitignore`, for example:

```gitignore
.env
.env.*
!.env.example
```

## Example workflow

```bash
cd ~/Scripts/my-project

deploy upload dry            # check what will be sent
deploy upload up             # sync and rebuild containers
deploy logs api              # follow the logs

# changed a production variable:
deploy upload-env restart
```

## Notes

- Commands that touch the server require `REMOTE_HOST` (from `common.conf`) and `REMOTE_DIR` (from `deploy.conf`).
- `deploy.conf` and `common.conf` are sourced as bash, so only use files you trust.
- Don't commit real hostnames, keys or secrets. If you publish your own `common.conf`, keep placeholders in it.

## License

MIT