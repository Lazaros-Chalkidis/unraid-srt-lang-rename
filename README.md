# unraid-srt-lang-rename

Renames Greek subtitle files from the deprecated `gre` code to `ell` on Unraid.

```
Movie.2020.gre.srt  ->  Movie.2020.ell.srt
```

Plex, Jellyfin and Kodi expect ISO 639-2/T `ell`. Files tagged `gre` are either ignored or show up as an unnamed track that has to be picked by hand. On a library of any size that is not something you fix manually.

The same script can be retargeted at other language code migrations. See [Other language codes](#other-language-codes).

## How it works

The script walks each volume under `/mnt` separately, finds `*.gre.srt` and renames every match to `*.ell.srt`. Matching is case insensitive, so `.GRE.SRT` and `.Gre.Srt` are handled as well.

Scanning per volume rather than through `/mnt/user` is deliberate. shfs adds real overhead on a large tree, and a single continuous walk over a big library can inflate the dentry cache far enough to trip Unraid's memory notification. Several shorter walks do not.

There is also no `/mnt/user0` fallback. That mount point is deprecated and may be removed in a future Unraid release. Worse, an empty share stub left behind on the array is enough to make an auto-detecting script scan an empty directory and report a clean run while doing nothing at all. Scripts that pick `BASE` automatically are prone to this. This one does not.

## Requirements

Unraid 7.x with the [User Scripts](https://forums.unraid.net/topic/48286-plugin-user-scripts/) plugin from Community Applications. Tested on 7.3.2. Nothing in it is version specific.

## Install

1. Settings, User Scripts, Add New Script
2. Give it a name, for example `srt rename gre to ell`
3. Gear icon, Edit Script, paste the contents of [`srt_rename_gre_to_ell.sh`](./srt_rename_gre_to_ell.sh)
4. Adjust the settings at the top of the script
5. Save

## Settings

Near the top of the script:

| Variable | Default | What it does |
|---|---|---|
| `MNT` | `/mnt` | Where volumes are mounted. Leave alone unless your setup is unusual. |
| `SUBROOTS` | `Media/Movies`, `Media/TV Shows` | Paths to look for inside each volume. A volume is scanned only if at least one of these exists in it. |
| `VOL_SKIP` | `user user0 disks remotes addons rootshare` | Entries under `/mnt` that are not real storage. |
| `LOG` | `/mnt/user/appdata/srt_rename_gre_to_ell.log` | Log file. |
| `STATE` | `..._gre_to_ell.last_run` | Timestamp used by incremental mode. |
| `SUCCESS_MARK` | `..._gre_to_ell.last_success` | Touched only on a clean run. |
| `LOG_MAX_LINES` | `5000` | Log is trimmed to this at the start of every run. |
| `HEARTBEAT_SECS` | `60` | Progress line interval during long scans. |

`/mnt/cache` is intentionally not in `VOL_SKIP`, so files still sitting on cache before the mover runs get picked up.

## Flags

| Flag | What it does |
|---|---|
| `--dry-run` | Show what would happen, change nothing. Run this first. |
| `--full` | Scan everything. This is the default. |
| `--inc` | Only files newer than the last successful run. |
| `--force` | Rename even when the `.ell.srt` target already exists, overwriting it. |
| `--dedupe` | See below. |
| `--drop-caches` | Drop dentries and inodes between volumes. Only worth using on a low memory server. |
| `--wake`, `--nowake` | Accepted and ignored. Kept so older scheduled entries do not fail. |

`--dedupe` and `--force` refuse to run together. One deletes the source, the other overwrites the target.

The **Run Script** button in User Scripts does not pass arguments. Put them in the Script Arguments field, or call the script from a terminal:

```
bash "/boot/config/plugins/user.scripts/scripts/srt rename gre to ell/script" --dry-run
```

## Dedupe

If something in the stack re-creates a `.gre.srt` after the script has already renamed it, both files end up sitting side by side. Normal runs skip these forever, so they accumulate quietly and never show up as an error.

`--dedupe` deletes the `.gre.srt` only when `cmp -s` confirms it is byte for byte identical to the `.ell.srt` next to it. If the two differ, both are kept and the file is logged as `DIFFER` for manual review.

Dry run first:

```
bash /path/to/script --dedupe --dry-run
```

This is a cleanup pass, not something to schedule. It does not touch the state file.

Worth saying plainly: dedupe treats the symptom. If duplicates keep coming back, find whatever writes them and fix it there.

## Safety

- `.Recycle.Bin` directories are pruned
- Nothing is overwritten without `--force`
- Nothing is deleted without a byte comparison first
- If no volume contains any of the `SUBROOTS`, the script aborts before scanning instead of reporting a successful run over nothing
- Every rename stays inside a single volume, so this never moves files between a user share path and a disk share path
- `renice` and `ionice` keep it out of the way of active streams

## Log output

Written to the log file and to syslog under the `srt-rename` tag.

```
[2026-01-01 04:00:01] Volumes with content: 6
[2026-01-01 04:00:01] Scanning: /mnt/pool_a/Media/TV Shows
[2026-01-01 04:00:01] Renamed: /mnt/pool_a/Media/TV Shows/Show/Season 01/Show - S01E01.gre.srt -> /mnt/pool_a/Media/TV Shows/Show/Season 01/Show - S01E01.ell.srt
[2026-01-01 04:00:01] Finished volume: /mnt/pool_a | found=1 renamed=1 deleted=0
[2026-01-01 04:00:02] TOTAL: Found=1 | Renamed=1 | Deleted=0 | Differ=0 | Skipped=0 | Errors=0 | Duration=00:00:01
```

## Other language codes

The suffixes are not parameterised, but retargeting is three small edits.

**1. The find pattern.** In `scan_dir`, both branches:

```bash
\( -type f -iname "*.gre.srt" -print0 \)
```

**2. The suffix test.** In `process_one`, the number is the character count of the source suffix including both dots:

```bash
local tail8="${file: -8}"
if [[ "${tail8,,}" != ".gre.srt" ]]; then
```

**3. The replacement.** Same number again, followed by the new suffix:

```bash
local new_file="${file:0:${#file}-8}.ell.srt"
```

Both numbers must match the source suffix length. The target suffix does not have to be the same length as the source.

Worked examples:

| Migration | Source suffix | Length | Target suffix |
|---|---|---|---|
| `gre` to `ell` | `.gre.srt` | 8 | `.ell.srt` |
| `heb` to `he` | `.heb.srt` | 8 | `.he.srt` |
| `iw` to `he` | `.iw.srt` | 7 | `.he.srt` |
| `fre` to `fra` | `.fre.srt` | 8 | `.fra.srt` |
| `ger` to `deu` | `.ger.srt` | 8 | `.deu.srt` |

For `iw` to `he` the three edits become:

```bash
\( -type f -iname "*.iw.srt" -print0 \)

local tail8="${file: -7}"
if [[ "${tail8,,}" != ".iw.srt" ]]; then

local new_file="${file:0:${#file}-7}.he.srt"
```

The variable is still called `tail8`, which is now a lie. Rename it if that bothers you.

Other subtitle extensions work the same way. For `.ass` or `.sub`, change the extension in all three places and recount the length.

Cosmetic but worth doing at the same time: the banner `echo` at the top, the `LOG`, `STATE` and `SUCCESS_MARK` filenames, and the `logger -t srt-rename` tag all still say `gre` to `ell`.

Always run `--dry-run` after retargeting.

## License

MIT. See [LICENSE](./LICENSE).
