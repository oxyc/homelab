# Plan (AUDITED): Reolink CX820 + Reolink Doorbell → Frigate + HomeKit Secure Video

## Verdict: HYBRID topology, not one hub for everything
- **CX820 camera → go2rtc/Frigate is the hub.** Scrypted pulls a restream. (Your "Scrypted first" instinct is *wrong* for the camera.)
- **Doorbell → Scrypted connects DIRECTLY to the doorbell.** Frigate gets a restream of it. (Your "Scrypted first" instinct is *right* for the doorbell.)

Reason: the doorbell **press event + two-way audio are NOT in the video stream** — they need Scrypted talking straight to the doorbell by IP (ONVIF backchannel + native press event). You cannot route those through go2rtc. The CX820 has no such requirement, so it follows the efficient go2rtc-hub model.

## Camera facts that force the design
- CX820 main = **3840×2160 H.265, locked** (no high-res H.264). Sub = low-res H.264.
- Doorbell main ≈ 2K (4:3) H.265; sub H.264. HomeKit letterboxes 4:3.
- HomeKit/HKSV need **H.264** → a HEVC→H.264 transcode is unavoidable for the Apple path unless the low-res H.264 sub is acceptable.
- Reolink 8MP+ streaming is firmware-fragile: native go2rtc **FLV producer now parses HEVC**, but community reliability at 8MP is mixed → **try FLV, fall back to RTSP**, validate on your firmware.
- HW transcode (VAAPI/QSV/NVENC) is **mandatory** here — Scrypted prebuffers 24/7.

## Topology
```
CX820 ──1 conn──> go2rtc (Frigate)  ──passthrough──┬─ Frigate record (native 4K H265, copy)
                                                    ├─ Frigate detect (H264 sub)
                                                    └─ Scrypted ← pulls restream; does HomeKit live + HKSV
                                                         (Scrypted transcodes HEVC→H264 on-demand, HW accel)

Doorbell ──Scrypted DIRECT (native Reolink plugin, Doorbell checkbox)── HomeKit doorbell + HKSV + 2-way
   └──also──> go2rtc restream (#backchannel=0) ──> Frigate record/detect
```

## go2rtc config (in Frigate `go2rtc:` block) — CORRECTED
```yaml
go2rtc:
  streams:
    # CX820 — native FLV (HEVC ok); query-param auth, NOT user:pass@
    front_main:
      - http://CAM_IP/flv?port=1935&app=bcs&stream=channel0_main.bcs&user=USER&password=PASS
      # RTSP fallback if FLV flaky on your firmware:
      # - rtsp://USER:PASS@CAM_IP:554/h264Preview_01_main#backchannel=0
    front_sub:
      - http://CAM_IP/flv?port=1935&app=bcs&stream=channel0_ext.bcs&user=USER&password=PASS

    # Doorbell — RTSP (FLV can't carry backchannel). Keep backchannel ON for talk-back stream only.
    doorbell_main:
      - rtsp://USER:PASS@DOORBELL_IP:554/h264Preview_01_main
    doorbell_sub:
      - rtsp://USER:PASS@DOORBELL_IP:554/h264Preview_01_sub#backchannel=0
```
- **No go2rtc transcode block.** Pre-transcoding for Scrypted is redundant (Scrypted prebuffers it → 24/7 GPU) and the `#raw=`+`#hardware` combo is *broken* in go2rtc (profile/level/GOP get overridden, downscale dropped → silently transcodes at 4K). Let Scrypted transcode on-demand instead.
- If you DO ever need go2rtc to transcode, the only correct form is `#video=h264#width=1920#height=1080#hardware=vaapi#audio=copy` PLUS a YAML template override `ffmpeg: { h264/vaapi: "-c:v h264_vaapi -g 120 -bf 0 -profile:v main -level:v 4.0 -sei:v 0" }`. GOP must be **4×fps** (120 @30fps), not 60.
- Audio: pass **native AAC** (`#audio=copy`) to Scrypted — NOT Opus. Scrypted makes Opus for live + AAC for recording itself.

## Frigate cameras
```yaml
cameras:
  front:
    ffmpeg:
      inputs:
        - { path: rtsp://127.0.0.1:8554/front_main, roles: [record] }   # native H265
        - { path: rtsp://127.0.0.1:8554/front_sub,  roles: [detect] }
  doorbell:
    ffmpeg:
      inputs:
        - { path: "rtsp://127.0.0.1:8554/doorbell_main?backchannel=0", roles: [record] }
        - { path: rtsp://127.0.0.1:8554/doorbell_sub, roles: [detect] }
```

## Scrypted
- **CX820:** add via RTSP/ONVIF, video = `rtsp://<frigate>:8554/front_main` (+ front_sub). Enable Rebroadcast (prebuffer), HomeKit, HKSV. Pair accessory mode. HKSV motion: Frigate MQTT bridge (`scrypted-frigate-bridge`) OR camera ONVIF OR Scrypted software motion. HW transcode on.
- **Doorbell:** use the **native Reolink plugin** with the **Doorbell** checkbox (NOT generic ONVIF — manufacturer plugin is Scrypted's recommended path for press + two-way; ONVIF only if firmware breaks it). Scrypted connects to the doorbell **directly by IP**. Frigate consumes the go2rtc restream of the doorbell.
- iCloud+ (1cam/50GB, 5cam/200GB, unlimited/2TB+) + Apple Home Hub (Apple TV/HomePod) required for HKSV.

## Expectation-setting
- CX820 HKSV will be a **transcoded ~1080p H.264** (4K HEVC can't go to Apple natively) — fine, not its sharpest. HW accel keeps CPU low.
- Running Frigate record + HKSV = intentional double-record; worth it only for Apple-native notifications/family UX.
- Validate Reolink streaming form (FLV vs RTSP) on your actual firmware before committing.
