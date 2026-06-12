#!/bin/bash

set -e

BOINC_SUMMARY="idle (no project configured)"
CPU_SUMMARY="not started"
MEM_SUMMARY="not started"
GPU_SUMMARY="Disabled (no GPU encoder available)"
BGPIDS=()

cleanup() {
  echo "Shutdown signal received. Stopping load generators..."
  trap - INT TERM
  for pid in "${BGPIDS[@]}"; do
    kill "$pid" 2> /dev/null || true
  done
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

# --- CPU load ---
echo "Starting CPU load (all cores, nice=19)..."
nice -n 19 stress-ng --cpu 0 --cpu-method all --timeout 24h &
BGPIDS+=($!)
CPU_SUMMARY="stress-ng --cpu 0 --cpu-method all (all cores, nice=19)"

# --- Memory load ---
echo "Starting memory load (80% RAM)..."
stress-ng --vm 1 --vm-bytes 80% --vm-method all --timeout 24h &
BGPIDS+=($!)
MEM_SUMMARY="stress-ng --vm 1 --vm-bytes 80%"

# --- GPU source ---
# Default: synthetic 1080p60 via lavfi - no download, no disk I/O, consistent load.
# Set VIDEO_URL to override with a real file.
if [ -n "$VIDEO_URL" ]; then
  VIDEO_FILE="test.mp4"
  if [ -f "$VIDEO_FILE" ]; then
    echo "Using existing video file: $VIDEO_FILE"
  else
    echo "Downloading video from: $VIDEO_URL"
    if ! curl -fsSL -o "$VIDEO_FILE" "$VIDEO_URL"; then
      echo "Download failed - falling back to synthetic source"
      VIDEO_URL=""
    fi
  fi
fi

if [ -n "$VIDEO_URL" ] && [ -f "test.mp4" ]; then
  GPU_INPUT="-stream_loop -1 -i test.mp4"
  GPU_INPUT_DESC="test.mp4 (looping)"
else
  GPU_INPUT="-f lavfi -i testsrc2=size=1920x1080:rate=60"
  GPU_INPUT_DESC="synthetic 1080p60 (lavfi)"
fi

# --- GPU detection ---
echo "Detecting GPU..."
GPU_INFO=$(lspci 2> /dev/null | grep -E "VGA|Display|3D" | head -n 1 || true)
echo "GPU_INFO: ${GPU_INFO:-none detected via lspci}"

HAS_DRI=0
HAS_VAAPI_ENCODER=0
HAS_VAAPI_RUNTIME=0
HAS_QSV_ENCODER=0
HAS_NVENC_ENCODER=0
HAS_NVENC_RUNTIME=0
NVIDIA_DETECTED=0
VAAPI_DEVICE=""

if [ -e /dev/dri/renderD128 ] || [ -e /dev/dri/card0 ]; then
  HAS_DRI=1
fi

if [ -e /dev/dri/renderD128 ]; then
  VAAPI_DEVICE="/dev/dri/renderD128"
elif [ -e /dev/dri/card0 ]; then
  VAAPI_DEVICE="/dev/dri/card0"
fi

if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_vaapi"; then HAS_VAAPI_ENCODER=1; fi
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_qsv"; then HAS_QSV_ENCODER=1; fi
if ffmpeg -hide_banner -encoders 2> /dev/null | grep -q "h264_nvenc"; then HAS_NVENC_ENCODER=1; fi

# VAAPI runtime test
if [ "$HAS_VAAPI_ENCODER" -eq 1 ] && [ -n "$VAAPI_DEVICE" ]; then
  if ffmpeg -hide_banner -loglevel error \
    -vaapi_device "$VAAPI_DEVICE" \
    -f lavfi -i testsrc=size=128x72:rate=1 \
    -vf 'format=nv12,hwupload' \
    -frames:v 1 -an -c:v h264_vaapi -f null - > /dev/null 2>&1; then
    HAS_VAAPI_RUNTIME=1
  fi
fi

# NVIDIA detection: lspci shows nothing inside most containers, so also check
# device nodes injected by nvidia-container-toolkit and nvidia-smi.
if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
  NVIDIA_DETECTED=1
elif [ -e /dev/nvidia0 ] || [ -e /dev/nvidiactl ]; then
  NVIDIA_DETECTED=1
  echo "NVIDIA device nodes detected (lspci unavailable in container)"
elif command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null 2>&1; then
  NVIDIA_DETECTED=1
  echo "NVIDIA detected via nvidia-smi"
fi

# NVENC runtime test (consistent with QSV/VAAPI validation above)
if [ "$NVIDIA_DETECTED" -eq 1 ] && [ "$HAS_NVENC_ENCODER" -eq 1 ]; then
  if ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc=size=128x72:rate=1 \
    -frames:v 1 -an -c:v h264_nvenc -f null - > /dev/null 2>&1; then
    HAS_NVENC_RUNTIME=1
  fi
fi

# --- GPU encode selection ---

if echo "$GPU_INFO" | grep -qi "Intel" && [ "$HAS_QSV_ENCODER" -eq 1 ]; then
  export LIBVA_DRIVER_NAME=iHD
  if ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc=size=128x72:rate=1 \
    -frames:v 1 -an -c:v h264_qsv -f null - > /dev/null 2>&1; then
    echo "Intel GPU - using Quick Sync (QSV)"
    # shellcheck disable=SC2086
    ffmpeg $GPU_INPUT -c:v h264_qsv -preset veryslow -b:v 40M -f null - &
    BGPIDS+=($!)
    GPU_SUMMARY="FFmpeg QSV: $GPU_INPUT_DESC (h264_qsv veryslow, 40M)"
  elif [ "$HAS_VAAPI_RUNTIME" -eq 1 ]; then
    echo "Intel QSV unavailable at runtime - falling back to VAAPI"
    # shellcheck disable=SC2086
    ffmpeg -vaapi_device "$VAAPI_DEVICE" $GPU_INPUT \
      -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 40M -f null - &
    BGPIDS+=($!)
    GPU_SUMMARY="FFmpeg VAAPI: $GPU_INPUT_DESC (Intel fallback, 40M)"
  else
    echo "Intel GPU: QSV and VAAPI both unavailable at runtime"
    GPU_SUMMARY="Disabled (Intel QSV/VAAPI unavailable at runtime)"
  fi

elif [ "$NVIDIA_DETECTED" -eq 1 ] && [ "$HAS_NVENC_RUNTIME" -eq 1 ]; then
  echo "NVIDIA GPU - using NVENC (preset p7 for maximum utilisation)"
  # shellcheck disable=SC2086
  ffmpeg $GPU_INPUT -c:v h264_nvenc -preset p7 -b:v 40M -f null - &
  BGPIDS+=($!)
  GPU_SUMMARY="FFmpeg NVENC: $GPU_INPUT_DESC (h264_nvenc p7, 40M)"

elif echo "$GPU_INFO" | grep -qi "AMD" && [ "$HAS_VAAPI_RUNTIME" -eq 1 ]; then
  echo "AMD GPU - using VAAPI"
  # shellcheck disable=SC2086
  ffmpeg -vaapi_device "$VAAPI_DEVICE" $GPU_INPUT \
    -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 40M -f null - &
  BGPIDS+=($!)
  GPU_SUMMARY="FFmpeg VAAPI: $GPU_INPUT_DESC (AMD h264_vaapi, 40M)"

elif [ "$HAS_VAAPI_RUNTIME" -eq 1 ]; then
  echo "GPU vendor not identified - trying generic VAAPI"
  # shellcheck disable=SC2086
  ffmpeg -vaapi_device "$VAAPI_DEVICE" $GPU_INPUT \
    -vf 'format=nv12,hwupload' -c:v h264_vaapi -b:v 40M -f null - &
  BGPIDS+=($!)
  GPU_SUMMARY="FFmpeg VAAPI: $GPU_INPUT_DESC (generic VAAPI, 40M)"

elif [ -e /dev/dxg ] && [ "$HAS_DRI" -ne 1 ]; then
  echo "WSL /dev/dxg detected but /dev/dri not available - GPU idle"
  echo "Hint: DirectML compute mode will be added in a future update."
  GPU_SUMMARY="Disabled (WSL: /dev/dri not present, DirectML not yet supported)"

elif [ "$NVIDIA_DETECTED" -eq 1 ]; then
  echo "NVIDIA device found but NVENC failed - is nvidia-container-toolkit installed on the host?"
  GPU_SUMMARY="Disabled (NVIDIA found but NVENC unavailable - check nvidia-container-toolkit)"

else
  echo "No supported GPU detected - running CPU+memory load only"
  GPU_SUMMARY="Disabled (no GPU device found)"
fi

echo ""
echo "All load generators running."
echo "Load summary:"
echo "- BOINC:   $BOINC_SUMMARY"
echo "- CPU:     $CPU_SUMMARY"
echo "- Memory:  $MEM_SUMMARY"
echo "- GPU:     $GPU_SUMMARY"
wait
