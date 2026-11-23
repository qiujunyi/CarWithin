# CFMOTO 150SC-F (6.2-inch TFT) diagnostic plan

Status: protocol unverified; **not** a claim of CarPlay compatibility.

## Observed from user tests
- Official CFMOTO MotoPlay mirrors the entire iPhone screen, including Home Screen and Photos, over the dashboard Wi-Fi.
- iPhone joins an SSID beginning `CFMOTO-`; previous instrument IP observed as `192.168.0.1`.
- CarWithin's existing ZEEHO 6.2 profile fails to display video and reported a TCP 10711 error.
- A prior test reported media dimensions `1024×515`; treat this as an observation requiring confirmation, not necessarily the H.264 encoded frame size.

## Current code path
- `App/TailingConnection.swift`: `TailingDisplayProfile.zeeho62` encodes 1024×480 H.264.
- `TailingPorts.ios`: control 10922, auxiliary 10711, video 10710, announcement 10930.
- Auxiliary command `0x10` only accepts 1024×480 or 1024×488 for ZEEHO. It rejects 1024×515 before validating media identity.
- Auxiliary `0x70` requests media startup. Video `0x72` is a frame request in the existing PXC implementation.

## Diagnostic gates (do not conflate)
1. Identify dashboard and exact SSID/IP, record control/auxiliary/video connections and disconnect errors.
2. Record raw auxiliary command IDs and media dimensions, without disclosing credentials, signatures, or device identifiers.
3. Verify whether CFMOTO actually speaks the same PXC protocol before enabling ZEEHO-specific handshake behavior.
4. Only if PXC is confirmed: add a separate `cfmoto150scf` profile and negotiate dimensions. Keep 1024×480 as the initial even-height H.264 encoder test size; do **not** set the encoder height to 515.
5. Verify first video frame, subsequent frame requests, heartbeat, stop/reconnect, and user-visible display.
6. Only after stable video: test CarPlay session setup. Official screen mirroring is not proof of native CarPlay support.

## Safety and privacy
- Never commit Apple credentials, accessory authentication keys, device HUIDs, serial numbers, Wi-Fi passwords, or signing materials.
- Keep the existing ZEEHO profile unchanged until CFMOTO compatibility is demonstrated.
- Do not modify ECU, CAN, braking, or vehicle control functions.

## Installation blocker (independent)
- GitHub Actions produced an unsigned IPA, but both Sideloadly and AltServer fail during Apple ID login. No evidence yet of an IPA code-signing failure.
- Check `https://developer.apple.com/account/` for any pending free developer agreement; verify Windows time/time zone and Apple desktop client sign-in. If login still fails, test an alternate Apple ID or a Mac with Xcode Personal Team. No workaround guarantees success.
