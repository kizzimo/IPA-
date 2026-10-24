# KIZZIMO Daemon Control v3 — iPhone + Windows companion

This builds on the original **KIZZIMO Control** IPA and **does not require a jailbreak** for its on-device editor.

## Download the unsigned IPA

Go to the repository **Actions** page, open the latest successful **Build KIZZIMO unsigned iPhone IPA** run, and download **KIZZIMO-Control-UNSIGNED-IPA** under Artifacts. Unzip that artifact to obtain **KIZZIMO-Control-UNSIGNED.ipa**.

**Important:** This is *unsigned*. Sign it with your own provisioning method before installing. GitHub Actions compiling successfully does not mean the binary has been tested on iPhone 17 running iOS 26.5.1.

## Run the Windows companion

1. Download both **DaemonCompanion.py** and **START_DAEMON_COMPANION.bat** into the same folder.
2. Double-click **START_DAEMON_COMPANION.bat**. It uses the Python already on your Windows PC. No pip packages required.
3. Run **ipconfig** and find your active Wi-Fi adapter's private IPv4 address (usually **192.168.x.x**).
4. Keep the console open; it displays a random **pairing token**. If Windows Firewall asks, allow only **Private networks**.
5. Open the **Daemons** tab on the IPA. Enter the computer's IPv4 address and the pairing token. Tap **Test**, select a preset, then **Send draft**.
6. The generated **latest.plist** and **latest.json** are saved under **%LOCALAPPDATA%\KIZZIMO_DaemonBridge** on Windows. Historical versions are in its **staged** subfolder.

The companion binds to TCP port 8765 and accepts only local/private-network clients. It requires the token to stage files. Transport uses unencrypted HTTP, so use a trusted private network, not a public Wi-Fi. The token is stored in the IPA's iOS Keychain.

## Presets

| Preset | Stages disabled entries for |
| --- | --- |
| Restore Draft | Clears overrides to the imported source (NOT device restoration) |
| Balanced | Tips |
| Performance | Tips, Game Center, AirPrint, UsageTrackingAgent |
| Extreme | Performance, atwakeup, Personal Hotspot, Voice/Assistant, Spotlight/indexers |
| Custom | Manual enable/disable/remove for individual labels |

The labels come from Nugget's daemon catalogue; actual installed service names and their behaviour vary by OS build. Not every label is guaranteed to exist.

Disabling optional daemons can break features: **Extreme is not necessarily faster**. Core thermal, selected logging, update, diagnostics, location, health and security labels are protected in the preset editor and Windows validator. Other custom changes are not safety-reviewed.

## Exactly what works

- On iPhone: choose presets, stage daemon labels, import plist, export XML/JSON, save manual edits, send files to the local Windows receiver.
- On Windows: token-authenticated receiver validates the request, blocks protected entries, writes a real XML plist and an audit JSON, retains historical drafts and returns **STAGED_ONLY** receipts.
- The companion deliberately returns HTTP **409** to \`POST /apply\`: no privileged restore implementation is verified for **iOS 26.5.1**. It never stops, restarts, or disables a live daemon.

**Nugget's documented BookRestore compatibility extends to iOS 26.1, not 26.5.1.** No code in this project assumes unverified restore methods work on your phone. Do not overwrite \`/var/db/com.apple.xpc.launchd/disabled.plist\` without an independently verified compatible restore mechanism and a full device backup.

## Test the companion

\`\`\`powershell
python DaemonCompanion.py --self-test
\`\`\`

Expected: \`PASS: staging files generated; protected daemon request rejected\`.

## Security and design notes

- No remote command execution or shell invocation in HTTP request handling.
- Pairing token comparison uses \`hmac.compare_digest\`; regenerate it by running \`python DaemonCompanion.py --rotate-token\` (update the IPA).
- A generated plist from the companion is an **offline draft** rather than an actual extraction from iOS. Always import your real baseline first if available.
- Use a device backup before any future external restore operation.
- The IPA's background app cannot stay running as an always-on privileged daemon on stock iOS.
