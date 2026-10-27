# NetSync

A native macOS **SwiftUI** app — a network volume browser with selective sync.

## Features

- Browse a mounted network volume (SMB / AFP / NFS) like Finder
- Choose which files and folders to keep on this Mac
- Two-way sync of changes
- Server-side Trash: deleted files stay on the volume for 15 days and can be restored
- Multiple connections and session restore

## Requirements

- macOS 14+
- Xcode 15+ (or `xcodegen` + `xcodebuild`)

## Build & Run

Open the project in Xcode and run the NetSync scheme.

Or from the terminal:

```bash
xcodebuild -scheme NetSync -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

## How to Use

1. Mount a network volume in Finder → Connect to Server… (`/Volumes/...`).
2. In NetSync, click **Connect Volume**.
3. Choose the network volume and a local sync folder.
4. Use **Keep on This Mac** on a file or folder.
5. Edits in the local copy go to the network and vice versa.

| Label | Meaning |
| --- | --- |
| **Local** | Synced and stored on this Mac |
| **Online** | Visible in the browser, not downloaded |

## Trash

Deleting an item moves it to a hidden folder on the network volume itself:

```
<network volume>/.tethwork-trash/
    index.json          original path, deletion date, pinned state
    <uuid>/<name>       the deleted file or folder
```

Because the payload stays on the share, all Macs connected to the same volume share the same Trash.

- Items are kept for **15 days**, then removed automatically (checked on connect, when Trash is opened, and hourly while the app is running).
- Deleting a **local synced copy in Finder** is tracked through the sync baseline and also moves the network copy to Trash (marked with a laptop icon) instead of deleting it permanently. This works even if the app was closed at the time of deletion — the baseline is persisted in `.tethwork-sync-state.json`.
- Open **Trash** in the sidebar (or ⌘⇧T) to see deleted files grouped by network connection, restore them to their original folder, or remove them permanently. Empty Trash affects all available connections.
- Restoring into a folder that already has an item with the same name adds a Finder-style ` 2` suffix instead of overwriting.
- Files that were kept on this Mac are downloaded again after restore.
