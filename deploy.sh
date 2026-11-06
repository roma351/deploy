#!/usr/bin/env bash
set -euo pipefail

# Команды (запускаются из папки проекта, где лежит deploy.conf):
#   deploy upload [dry] [restart]      rsync с учётом .gitignore
#   deploy upload-env [dry] [restart]  rsync только .env.* (не трогая сам .env)
#   deploy up                          docker compose up -d --build
#   deploy restart [сервис]            docker compose restart [сервис]
#   deploy logs [сервис]               docker compose logs -f --tail=100 [сервис]
#   deploy <алиас>                     своя команда из CMDS в common.conf
#
# common.conf лежит рядом с этим файлом (общие настройки + алиасы команд).
# deploy.conf лежит в папке каждого проекта (SRC = эта папка, свой REMOTE_DIR).

# разворачиваем symlink, чтобы найти common.conf рядом с РЕАЛЬНЫМ файлом

# ln -sf .env.prod .env

resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -h "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(resolve_script_dir)"

# --- общие настройки, лежат рядом со скриптом ---
REMOTE_HOST=""
REMOTE_BASE=""
SSH_PORT=22
SSH_KEY=""

# common.conf может (не обязательно) определить функцию cmd_alias(),
# которая по имени команды возвращает готовую shell-строку для запуска
# на сервере — так реализуются алиасы вроде "deploy ps". Без
# ассоциативных массивов, поэтому работает и на старом bash (Mac).
cmd_alias() { return 1; }

COMMON="$SCRIPT_DIR/common.conf"
# shellcheck disable=SC1090
[ -f "$COMMON" ] && source "$COMMON"

# --- конфиг проекта: ищем deploy.conf в ТЕКУЩЕЙ папке ---
PROJECT_DIR="$PWD"
PROFILE="$PROJECT_DIR/deploy.conf"

SRC=""
DEST=""
REMOTE_DIR=""

if [ -f "$PROFILE" ]; then
  # shellcheck disable=SC1090
  source "$PROFILE"
fi

[ -z "$SRC" ] && SRC="$PROJECT_DIR/"
if [ -z "$DEST" ] && [ -n "$REMOTE_DIR" ] && [ -n "$REMOTE_HOST" ]; then
  DEST="$REMOTE_HOST:$REMOTE_DIR/"
fi

SSH_CMD="ssh -p $SSH_PORT"
[ -n "$SSH_KEY" ] && SSH_CMD="$SSH_CMD -i $SSH_KEY"

usage() {
  cat <<EOF
Использование (из папки проекта с deploy.conf):
  deploy upload [dry] [restart|up]
  deploy upload-env [dry] [restart|up]
  deploy up
  deploy restart [сервис]
  deploy logs [сервис]
  deploy <алиас>                (см. cmd_alias в common.conf)
EOF
}

need_remote() {
  [ -n "$REMOTE_HOST" ] || { echo "REMOTE_HOST не задан (common.conf)"; exit 1; }
  [ -n "$REMOTE_DIR" ]  || { echo "В $PROFILE не задан REMOTE_DIR"; exit 1; }
}

do_up() {
  need_remote
  echo "==> up на $REMOTE_HOST:$REMOTE_DIR"
  ssh -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$REMOTE_HOST" \
    "cd $REMOTE_DIR && docker compose up -d --build"
}

do_restart() {
  local svc="${1:-}"
  need_remote
  echo "==> restart $svc на $REMOTE_HOST:$REMOTE_DIR"
  ssh -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$REMOTE_HOST" \
    "cd $REMOTE_DIR && docker compose restart $svc"
}

do_logs() {
  local svc="${1:-}"
  need_remote
  ssh -t -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$REMOTE_HOST" \
    "cd $REMOTE_DIR && docker compose logs -f --tail=100 $svc"
}

do_upload() {
  [ -n "$DEST" ] || { echo "DEST не определён — нет deploy.conf в этой папке?"; exit 1; }
  local dry="" chain_restart="" chain_up=""
  for a in "$@"; do
    [ "$a" = "dry" ] && dry="--dry-run"
    [ "$a" = "restart" ] && chain_restart=1
    [ "$a" = "up" ] && chain_up=1
  done

  # --include .env.example выше --filter — первое совпадение побеждает,
  # так .env.example не попадёт под .env.* из .gitignore
  local args=(--exclude '.git' --include '.env.example' --filter=':- .gitignore')

  echo "==> upload: $SRC -> $DEST"
  rsync -avz --checksum --delete --progress $dry -e "$SSH_CMD" "${args[@]}" "$SRC" "$DEST"

  if [ -z "$dry" ]; then
    [ -n "$chain_up" ] && do_up
    [ -n "$chain_restart" ] && do_restart
  fi
}

do_upload_env() {
  [ -n "$DEST" ] || { echo "DEST не определён — нет deploy.conf в этой папке?"; exit 1; }
  local dry="" chain_restart="" chain_up=""
  for a in "$@"; do
    [ "$a" = "dry" ] && dry="--dry-run"
    [ "$a" = "restart" ] && chain_restart=1
    [ "$a" = "up" ] && chain_up=1
  done

  # копируем только .env.* (не сам .env-симлинк), не заходя в мусорные
  # папки — сначала гасим их через .gitignore/.git, потом открываем
  # оставшиеся директории для обхода
  local args=(--exclude '.git' --include '.env.*' --filter=':- .gitignore' --include '*/' --exclude '*')

  echo "==> upload-env: $SRC -> $DEST"
  rsync -avz $dry -e "$SSH_CMD" "${args[@]}" "$SRC" "$DEST"

  if [ -z "$dry" ]; then
    [ -n "$chain_up" ] && do_up
    [ -n "$chain_restart" ] && do_restart
  fi
}

CMD="${1:-}"
[ $# -gt 0 ] && shift

case "$CMD" in
  ""|-h|--help)
    usage
    ;;
  up)
    do_up
    ;;
  restart)
    do_restart "${1:-}"
    ;;
  logs)
    do_logs "${1:-}"
    ;;
  upload)
    do_upload "$@"
    ;;
  upload-env)
    do_upload_env "$@"
    ;;
  *)
    if ALIAS_CMD="$(cmd_alias "$CMD")"; then
      [ -n "$REMOTE_HOST" ] || { echo "REMOTE_HOST не задан (common.conf)"; exit 1; }
      echo "==> $CMD на $REMOTE_HOST"
      ssh -p "$SSH_PORT" ${SSH_KEY:+-i "$SSH_KEY"} "$REMOTE_HOST" "$ALIAS_CMD"
    else
      echo "Неизвестная команда: $CMD"
      usage
      exit 1
    fi
    ;;
esac