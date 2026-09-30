<!-- Author: Lei Zhao <lei1.zhao@sk.com> -->

# Maintenance tools

Run these tools only when needed and review each script's help before making
changes.

| Script | Purpose |
| --- | --- |
| `diagnose_apt_sources.sh` | Diagnose APT, TLS, and network timeouts without making changes. |
| `inspect_mount_and_persist_existing_disk.sh` | Inspect an existing filesystem and persist its mount in `/etc/fstab`.<br>PS: This script never formats disks. |
| `grant_everyone_read_write_shared_storage.sh` | Give all users read/write access to the shared models and datasets on s1.<br>PS: Every user will be able to create, overwrite, and delete entries. |
| `repair_broken_s1_datasets_nfs_mount.sh` | Validate and repair a stale s1 datasets NFS mount. |
| `deduplicate_btrfs_files_with_jdupes.sh` | Deduplicate identical Btrfs files by sharing data extents with `jdupes`.<br>PS: Btrfs only; stop writers and keep a current backup. The script does not delete or hard-link files. |
