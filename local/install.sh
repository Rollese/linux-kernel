#!/usr/bin/env bash
# Restore the host-side build config that lives outside the repo.
# Usage: local/install.sh [install|save-db|status]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="${XDG_CONFIG_HOME:-$HOME/.config}"

link() {
  local src="$here/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -e $dst && ! -L $dst ]]; then
    echo "  backup  $dst -> $dst.bak"
    mv "$dst" "$dst.bak"
  fi
  ln -sfn "$src" "$dst"
  echo "  link    $dst -> $src"
}

case "${1:-install}" in
install)
  # Static config: symlink, so repo edits take effect immediately.
  link makepkg.conf "$conf/pacman/makepkg.conf"
  link ccache.conf  "$conf/ccache/ccache.conf"

  # The module database is written to every 6h by modprobed-db.timer, so it is
  # COPIED rather than symlinked. A symlink would leave the repo permanently
  # dirty and block `git rebase`. Use `save-db` to snapshot it back.
  if [[ -e $conf/modprobed.db ]]; then
    echo "  keep    $conf/modprobed.db (exists; run 'save-db' to update the repo copy)"
  else
    cp "$here/modprobed.db" "$conf/modprobed.db"
    echo "  copy    $conf/modprobed.db"
  fi

  echo
  echo "Packages needed:  sudo pacman -S --needed ccache modprobed-db"
  echo "Keep the db fed:  systemctl --user enable --now modprobed-db.service"
  ;;
save-db)
  cp "$conf/modprobed.db" "$here/modprobed.db"
  echo "saved $(wc -l < "$here/modprobed.db") modules into local/modprobed.db"
  ;;
status)
  printf '%-34s %s\n' "$conf/pacman/makepkg.conf" "$(readlink -f "$conf/pacman/makepkg.conf" 2>/dev/null || echo MISSING)"
  printf '%-34s %s\n' "$conf/ccache/ccache.conf"  "$(readlink -f "$conf/ccache/ccache.conf" 2>/dev/null || echo MISSING)"
  printf '%-34s %s\n' "$conf/modprobed.db" "$( [[ -e $conf/modprobed.db ]] && echo "$(wc -l < "$conf/modprobed.db") modules" || echo MISSING)"
  echo "repo copy: $(wc -l < "$here/modprobed.db") modules"
  command -v ccache >/dev/null && ccache -s 2>/dev/null | grep -iE 'cacheable|hit rate|size' | head -4
  ;;
*)
  echo "usage: $0 [install|save-db|status]" >&2; exit 1 ;;
esac
