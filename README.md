# docker-power-draw

Containerized CPU/GPU power draw workload with optional BOINC attachment.

This image runs three types of load:
- BOINC client (optional project/account-manager attach)
- CPU load via `stress-ng`
- GPU video transcode loop via `ffmpeg` when supported hardware/encoders are available

## What It Does

At startup, the container:
1. Starts BOINC.
2. Optionally attaches BOINC using environment variables.
3. Ensures a test video exists (downloads open-source video, or generates one if download fails).
4. Starts CPU load with `stress-ng`.
5. Detects GPU/encoder support and starts hardware-accelerated `ffmpeg` load when possible.
6. Prints a load summary (BOINC/CPU/GPU status).

If no supported GPU path is available, GPU load is skipped and CPU load still runs.

## Build

```bash
docker build -t docker-power-draw .
```

## Run

Minimal run:

```bash
docker run --rm --name power-draw docker-power-draw
```

Run with `/dev/dri` (recommended for Intel/AMD VAAPI/QSV paths):

```bash
docker run --rm --name power-draw --device /dev/dri docker-power-draw
```

Run with BOINC project attach:

```bash
docker run --rm --name power-draw \
	--device /dev/dri \
	-e BOINC_PROJECT_URL=https://www.worldcommunitygrid.org \
	-e BOINC_ACCOUNT_KEY=YOUR_KEY \
	docker-power-draw
```

## Environment Variables

BOINC attach precedence in startup script:
1. `BOINC_PROJECT_URL` + `BOINC_ACCOUNT_KEY`
2. `BOINC_BAM_EMAIL` + `BOINC_BAM_PASSWORD`
3. `BOINC_DEFAULT_KEY` (defaults to World Community Grid attach)
4. If none are set, BOINC idles

Video source override:
- `VIDEO_URL` (optional): custom URL for input video download

## GPU Behavior

The script attempts GPU load in this order:
- Intel + `h264_qsv`
- AMD + VAAPI (`h264_vaapi`)
- NVIDIA + NVENC (`h264_nvenc`)
- Generic VAAPI fallback when `/dev/dri` and VAAPI encoder are available

If these are not available, it runs CPU-only mode (no continuous ffmpeg GPU loop).

## Shutdown Behavior

`Ctrl+C` (SIGINT) and SIGTERM are trapped for graceful exit:
- Stops background `ffmpeg` (if running)
- Stops `stress-ng`
- Sends `boinccmd --quit`
- Waits for child processes and exits cleanly

## Exposed Port

- `31416` (BOINC RPC, optional)

The container exposes this port in the image metadata, but you only need to publish it with `-p` if you want host access.

## Notes

- This image includes `curl`, so video download uses `curl` directly.
- If internet download fails, startup generates a synthetic test video with `ffmpeg` and continues.
