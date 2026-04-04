#!/bin/bash

set -e

BOINC_SUMMARY="idle (no project configured)"
CPU_SUMMARY="not started"
GPU_SUMMARY="Disabled (no GPU encoder available)"
STRESS_PID=""
FFMPEG_PID=""

cleanup() {
  echo "Shutdown signal received. Stopping load generators..."
  trap - INT TERM

  if [ -n "$FFMPEG_PID" ] && kill -0 "$FFMPEG_PID" 2> /dev/null; then
    kill "$FFMPEG_PID" 2> /dev/null || true
  fi

  if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2> /dev/null; then
    kill "$STRESS_PID" 2> /dev/null || true
  fi

  boinccmd --quit > /dev/null 2>&1 || true
  wait || true
  exit 0
}

trap cleanup INT TERM

echo "Starting BOINC client..."
boinc --daemon
sleep 5

# BOINC attachment logic
if [ -n "$BOINC_PROJECT_URL" ] && [ -n "$BOINC_ACCOUNT_KEY" ]; then
  echo "Attaching to specific BOINC project: $BOINC_PROJECT_URL"
  boinccmd --project_attach "$BOINC_PROJECT_URL" "$BOINC_ACCOUNT_KEY" || echo "Project attach failed."
  BOINC_SUMMARY="attached to project: $BOINC_PROJECT_URL"
elif [ -n "$BOINC_BAM_EMAIL" ] && [ -n "$BOINC_BAM_PASSWORD" ]; then
  echo "Attaching to BAM! account manager..."
  boinccmd --acct_mgr attach https://bam.boincstats.com "$BOINC_BAM_EMAIL" "$BOINC_BAM_PASSWORD" || echo "BAM! attach failed."
  BOINC_SUMMARY="attached to BAM! account manager"
elif [ -n "$BOINC_DEFAULT_KEY" ]; then
  echo "No specific project configured. Attaching to World Community Grid by default..."
  boinccmd --project_attach https://www.worldcommunitygrid.org "$BOINC_DEFAULT_KEY" || echo "WCG attach failed."
  BOINC_SUMMARY="attached to project: https://www.worldcommunitygrid.org"
else
  echo "No BOINC project or account manager configured. BOINC will idle."
fi

VIDEO_FILE="test.mp4"
VIDEO_URL="${VIDEO_URL:-https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4}"

if [ -f "$VIDEO_FILE" ]; then
  echo "Using existing video file: $VIDEO_FILE"
else
  echo "Attempting to download open-source video from: $VIDEO_URL"
  if curl -fsSL -o "$VIDEO_FILE" "$VIDEO_URL"; then
    echo "Open-source video downloaded successfully."
  else
    echo "Download failed or internet unavailable. Generating synthetic video instead..."
    ffmpeg -y -f lavfi -i testsrc=duration=3600:size=1920x1080:rate=30 "$VIDEO_FILE"
  fi
fi

echo "Starting CPU load (nice priority)..."
nice -n 19 stress-ng --cpu 0 --cpu-method all --timeout 24h &
STRESS_PID=$!
CPU_SUMMARY="stress-ng --cpu 0 --cpu-method all --timeout 24h (nice=19)"

echo "Detecting GPU type..."
GPU_INFO=$(lspci | grep -E "VGA|Display" | head -n 1 || true)
echo "GPU_INFO: $GPU_INFO"

HAS_DRI=0
HAS_VAAPI_ENCODER=0
HAS_QSV_ENCODER=0
HAS_NVENC_ENCODER=0

if [ -e /dev/dri/renderD128 ] || [ -e /dev/dri/card0 ]; then
  HAS_DRI=1
fi

if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_vaapi"; then
  HAS_VAAPI_ENCODER=1
fi
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_qsv"; then
  HAS_QSV_ENCODER=1
fi
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_nvenc"; then
  HAS_NVENC_ENCODER=1
fi

if echo "$GPU_INFO" | grep -qi "Intel" && [ "$HAS_QSV_ENCODER" -eq 1 ]; then
  echo "Intel GPU detected — using Quick Sync (QSV)"
  export LIBVA_DRIVER_NAME=iHD
  ffmpeg -stream_loop -1 -i "$VIDEO_FILE" \
    -c:v h264_qsv -b:v 20M -f null - &
  FFMPEG_PID=$!
  GPU_SUMMARY="FFmpeg QSV transcode loop on $VIDEO_FILE (h264_qsv, 20M)"

elif echo "$GPU_INFO" | grep -qi "AMD" && [ "$HAS_DRI" -eq 1 ] && [ "$HAS_VAAPI_ENCODER" -eq 1 ]; then
  echo "AMD GPU detected — using VAAPI"
  ffmpeg -stream_loop -1 -i "$VIDEO_FILE" \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -b:v 20M -f null - &
  FFMPEG_PID=$!
  GPU_SUMMARY="FFmpeg VAAPI transcode loop on $VIDEO_FILE (h264_vaapi, 20M)"

elif echo "$GPU_INFO" | grep -qi "NVIDIA" && [ "$HAS_NVENC_ENCODER" -eq 1 ]; then
  echo "NVIDIA GPU detected — using NVENC"
  ffmpeg -stream_loop -1 -i "$VIDEO_FILE" \
    -c:v h264_nvenc -preset fast -b:v 20M -f null - &
  FFMPEG_PID=$!
  GPU_SUMMARY="FFmpeg NVENC transcode loop on $VIDEO_FILE (h264_nvenc, 20M)"

elif [ "$HAS_DRI" -eq 1 ] && [ "$HAS_VAAPI_ENCODER" -eq 1 ]; then
  echo "GPU not identified by lspci (common in WSL/containers) — trying generic VAAPI"
  ffmpeg -stream_loop -1 -i "$VIDEO_FILE" \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -b:v 20M -f null - &
  FFMPEG_PID=$!
  GPU_SUMMARY="FFmpeg VAAPI transcode loop on $VIDEO_FILE (generic VAAPI, 20M)"

else
  if [ -e /dev/dxg ] && [ "$HAS_DRI" -ne 1 ]; then
    echo "WSL GPU interface detected (/dev/dxg), but /dev/dri is not available in this container."
    echo "FFmpeg VAAPI acceleration in this image requires /dev/dri, so running CPU-only mode."
  else
    echo "No supported GPU detected - running CPU-only mode."
    echo "Hint: In Docker on Linux/WSL with /dev/dri, pass --device=/dev/dri and ensure VAAPI drivers are installed in the image."
  fi
fi

echo "All load generators running."
echo "Load summary:"
echo "- BOINC: $BOINC_SUMMARY"
echo "- CPU:   $CPU_SUMMARY"
echo "- GPU:   $GPU_SUMMARY"
wait
