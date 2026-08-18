# Vendor Reference Material — Not In This Repository

This project was developed against manufacturer-provided SDK and
protocol reference material for the HY-16 (禾胜成/Heshengcheng, BES
chipset). That material is **not** included in this GitHub repository:

- `BES_android.zip`
- `BES_ios.zip`
- `BES_interface&command.docx`
- `BES_OTA_PROTOCOL_MULTIPLE.pdf`
- The extracted `BES_android/` folder (Android SDK, UI package, and an
  additional OTA protocol document)

These are the chipset/hardware manufacturer's own proprietary SDK
bundles and protocol documents. Redistribution rights for this material
are unclear, so per explicit decision it is being kept out of this
public-adjacent (private, but still third-party-hosted) repository
rather than committed without that clarity resolved. Separately,
`BES_android.zip` alone (151MB) exceeds GitHub's 100MB per-file limit and
would be rejected by a normal `git push` regardless of the redistribution
question.

## Where this material actually lives

As of this writing, the owner's copy is kept locally at:

```
~/Library/Mobile Documents/com~apple~CloudDocs/恒玄OTA相关的APP开发协议与SDK/
```

(an iCloud Drive folder, so it syncs across the owner's own Apple
devices, but is not shared via this GitHub repository). If you are
restoring this project on a new machine and need to consult the
manufacturer's own documentation, you will need to separately recover
that folder (from iCloud, a personal backup, or by re-obtaining the SDK
from the manufacturer/vendor directly) — this repository alone does not
contain or restore it.

## What you don't need it for

Everything this project has **independently, physically proven** by
testing against real HY-16 hardware — BLE UUIDs, protocol commands, and
observed device behavior — is documented in
`docs/HY16_PROTOCOL_NOTES.md`, which is part of this repository and
needs nothing from the vendor material to be understood or used. You
only need the original vendor material if you need to consult the
manufacturer's documentation directly (e.g. to investigate a command
this project hasn't proven or implemented yet).

## If you later obtain explicit redistribution clearance

If the manufacturer/vendor relationship clarifies that this material can
be shared (e.g. an explicit written permission, or the vendor publishes
it under an open license), it could be added later — likely via Git LFS
for the two `.zip` files given their size — as a deliberate follow-up
decision, not by default.
