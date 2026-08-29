# Local build tuning

Local modifications on top of upstream `linux-mauri870`, aimed purely at cutting
rebuild time. They do not change the kernel's runtime behaviour: ThinLTO, `-O3`,
`-march=native`, BORE, BBRv3, 1000 Hz, `PREEMPT_FULL`, sched_ext, NTSYNC and all
23 patches (including `0001-hdmi_frl.patch`) are untouched.

## Knobs

Set in `PKGBUILD`, overridable per-build from the environment:

| Variable             | Default                    | Effect |
|----------------------|----------------------------|--------|
| `_localmodcfg`       | `yes`                      | Run `make localmodconfig` to trim the module set |
| `_localmodcfg_path`  | `~/.config/modprobed.db`   | Module database used for the trim |
| `_incremental`       | `yes`                      | Keep build artifacts between builds |

Escape hatch — full stock build, exactly as upstream:

```sh
_localmodcfg=no _incremental=no makepkg -si -f
```

## 1. localmodconfig

The stock config builds **6228 modules**. Measured on this machine, trimming to
the module database leaves **161** — a ~97% cut in module compilation, plus a
much faster `modules_install` (zstd -19 over 161 files instead of 6228).

Verified to survive the trim: `amdgpu`, `xfs`, `nvme`, `usb_storage`, `vfat`,
`snd_hda_intel`, `i2c_piix4`; and as builtins `usb_xhci_pci`, `sata_ahci`,
`ext4`, `btrfs`, `drm`, `drm_amd_dc`, `efi_stub`, `sched_bore`.

**The database is the weak point.** It was seeded from this machine's currently
loaded modules plus every driver bound to a live PCI/USB/HID device. Anything
you have never plugged in is not in it and will not be built. Keep it fed:

```sh
sudo pacman -S modprobed-db
modprobed-db store                       # merge current lsmod into the db
systemctl --user enable --now modprobed-db.timer   # keep merging automatically
```

Note the seed was taken while booted on `linux-cachyos`, which splits
builtin-vs-module differently from this kernel. Re-run `modprobed-db store`
after booting the mauri870 kernel to pick up the difference.

If something is missing after a build, rebuild with `_localmodcfg=no` — the
CachyOS kernel remains installed as a fallback boot entry.

## 2. Incremental rebuilds

Upstream `prepare()` ran `git clean -fdx`, which deletes every `.o`, `.cmd` and
ThinLTO cache file, forcing a from-scratch compile on every build. With
`_incremental=yes` that is replaced by: keep all untracked build output, and
delete only the 7 source files the patch set creates (derived automatically from
`new file mode` lines, so it stays correct if patches are added or removed):

```
drivers/gpu/drm/amd/display/dc/hpo/dcn30/dcn30_hpo_hdmi_link_encoder.{c,h}
drivers/gpu/drm/amd/display/dc/hpo/dcn30/dcn30_hpo_hdmi_stream_encoder.{c,h}
include/linux/sched/bore.h
kernel/sched/bore.c
include/linux/lazy_percpu_counter.h
```

Those must go, otherwise `git apply` fails with "already exists".
`git reset --hard` then reverts the patched tracked sources. Verified: artifacts
survive the reset and all 21 patches re-apply cleanly on a second pass.

## 3. ccache

Enabled outside the repo so it survives `git pull`, in
`~/.config/pacman/makepkg.conf`:

```sh
BUILDENV=(!distcc color ccache check !sign)
```

makepkg prepends `/usr/lib/ccache/bin` to `PATH`, so `make LLVM=1` picks up the
ccache clang shim. Cache is capped at 30G in `~/.config/ccache/ccache.conf`.

```sh
sudo pacman -S ccache
ls /usr/lib/ccache/bin/clang   # must exist; if not:
# sudo ln -s /usr/bin/ccache /usr/lib/ccache/bin/clang
ccache -s                      # check hit rate after a build
```

ccache helps most when you rebuild the *same* version (failed build, patch
tweak, config toggle). Across rc bumps, header changes invalidate a lot of it —
that is what the incremental change above covers instead. The two are
complementary; the ThinLTO link step is not cacheable either way.

## Repo layout: fork + one commit

`origin` is the fork (`Rollese/linux-kernel`), `upstream` is `mauri870/linux-kernel`.
All local changes live in a **single commit** on a `local/<version>` branch, so
they rebase as one unit.

```sh
git fetch upstream
git rebase upstream/7.2                    # or upstream/7.3 to follow the rc line
git push --force-with-lease origin local/7.2
makepkg -si -f
```

`--force-with-lease` is expected: rebasing rewrites the commit. Turn on
`git config rerere.enabled true` so repeated conflict resolutions replay
automatically.

Upstream touches `PKGBUILD` in ~half its commits (`LINUX_COMMIT`, `source=()`),
but those sit away from the three hunks here, so conflicts should be rare —
expect them only when `prepare()` gets restructured.

To move to the 7.3 rc line:

```sh
git checkout -b local/7.3 && git rebase --onto upstream/7.3 upstream/7.2
```

Note 7.3 reworked `0001-hdmi_frl.patch` heavily ("fix conflicts on 0001 patch,
still broken" ... "fix 0001 patch, enable it back"). After a 7.3 build, confirm
4K120 RGB 10-bit actually negotiates instead of assuming it did.

## Host config (`local/`)

The ccache and modprobed-db setup lives outside the repo in `~/.config`, so it
is mirrored here and restored with:

```sh
sudo pacman -S --needed ccache modprobed-db
./local/install.sh install       # symlink makepkg.conf + ccache.conf, seed the db
systemctl --user enable --now modprobed-db.service   # pulls in the 6h timer
```

`makepkg.conf` and `ccache.conf` are **symlinked** (static). `modprobed.db` is
**copied**, because modprobed-db rewrites it every 6h and a symlink would leave
the repo permanently dirty and block `git rebase`. Snapshot it back when you
have picked up new hardware:

```sh
./local/install.sh save-db && git commit -am "local: refresh module db"
./local/install.sh status        # show what is linked + ccache hit rate
```

After a fresh OS install, one `git clone` of the fork plus `install.sh` restores
everything.
