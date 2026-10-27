# diskhound

> Sniff out what's eating your disk, then clear it one item at a time.

A tiny, dependency-free CLI for **macOS, Linux and Windows**. It shows where your space went, ranks the top 20 offenders, and walks you through deleting them one by one. Nothing is removed without your say-so.

```
1. Disk overview
   Total 237 GB   Used 214 GB (91%)   Free 23 GB

2. Biggest folders in ~
   Projects        61.2 GB  ####################
   .android        38.4 GB  ############
   Downloads       22.0 GB  #######

   Top space hogs
    1.   3.9 GB  Android emulator snapshots  ~/.android/avd/Small_Phone.avd/snapshots
    2.   2.1 GB  node_modules                ~/Projects/old-app/node_modules
    ...

[1/20] ~/.android/avd/Small_Phone.avd/snapshots
   3.9 GB  (Android emulator snapshots)
   [d]elete  [o]pen location  [s]kip  [q]uit >
```

## Install & run

```bash
git clone https://github.com/dobsnotnull/diskhound.git
cd diskhound
```

**macOS / Linux**
```bash
chmod +x diskhound.sh
./diskhound.sh              # scan your home folder
./diskhound.sh --dry-run    # rehearse without deleting
```

**Windows (PowerShell)**
```powershell
powershell -ExecutionPolicy Bypass -File .\diskhound.ps1
powershell -ExecutionPolicy Bypass -File .\diskhound.ps1 -DryRun
```

## Options

| Unix flag | PowerShell | What it does |
|---|---|---|
| `--top N` | `-Top N` | How many items to list (default 20) |
| `--min-mb N` | `-MinMB N` | Size threshold for large files (default 100) |
| `--dry-run` | `-DryRun` | Walk through everything, delete nothing |
| `[directory]` | `-Path <dir>` | Scan somewhere other than home |

## How it works

1. **Overview**: total, used and free space for the drive you're scanning.
2. **Breakdown**: the 10 biggest folders at the top level, with bars.
3. **Hunt**: gathers candidates from three sources: known caches (npm, Gradle, Xcode, Android emulator snapshots, Trash, temp), every `node_modules`, and any file over 100 MB. Merges, dedupes, and ranks them by size.
4. **Clean**: for each item you choose delete, open its location, skip, or quit.
5. **Extras**: optional Docker prune, npm cache, Homebrew/apt/dnf cleanup, journal trim, Windows Disk Cleanup.

## Safety

- Deletion is **permanent** (no Recycle Bin or Trash), and always needs a second `y` confirmation.
- It refuses to delete anything outside the folder being scanned.
- Virtual machine disks (`.vhdx`, `.vmdk`, `.vdi`, `.qcow2`) get a warning, since deleting one destroys that VM or WSL distro.
- Try `--dry-run` first. You are responsible for what you delete.

## License

MIT
