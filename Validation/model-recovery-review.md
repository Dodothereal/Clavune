# Bounded model recovery

The importer first copies within the manifest size bound, verifies the private temporary file, checks cancellation and marks that new file read-only. A valid existing installed model is reused without changing its inode.

A hash-mismatched regular destination may be recovered only if its recorded size is within the largest declared candidate size. A symlink, nonregular entry or oversized existing file is refused. Recovery retains exactly one backup for the whole managed model directory:

    .model-recovery.bin

The backup is never overwritten and no unrelated path is deleted. A pre-existing backup causes a precise recovery error, leaving both old destination and backup intact.

Activation uses Darwin renamex_np with RENAME_EXCL, available since macOS 10.12. The old inode is renamed to the backup, and the newly verified inode is renamed to the model filename. Existing readers or mappings retain the old inode. Each same-directory rename is atomic/no-overwrite on a supporting macOS filesystem; the pair is not one power-loss-atomic transaction.

The importer rechecks the old file's regular-file type, inode/volume identity and size after the failed hash check. This does not provide a filesystem transaction against another process modifying app-owned files; an existing writer can still modify its inode. The backup bound describes the importer's own retained file at the final check, not protection against arbitrary concurrent changes by the same OS user.

If activation fails, rollback restores the backup only if the destination is absent. A concurrently appearing destination is never overwritten. If rollback cannot complete, the old inode stays at the backup path with a precise recovery-required error. A crash after the first rename may leave an absent destination and the one backup; a later deliberate import can install verified bytes at the absent destination without removing that backup. No fsync or full durability guarantee is claimed.

Added six tiny synthetic SHA-256 fixtures covering corrupt replacement with an old open file handle, source preservation, valid inode reuse, existing-backup refusal, unverified incoming rejection, oversized-old-file refusal and symlink safety. No real model, inference or microphone is used. This reviewer has not run the fixtures or a build; the parent will run checks sequentially.

## Root execution evidence

Root ran the Swift suite: 48 XCTest cases, zero failures, including all six tiny model-recovery fixtures. No real model was used.
