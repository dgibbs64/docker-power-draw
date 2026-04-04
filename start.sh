#!/bin/bash

set -e

echo "Starting BOINC client..."
boinc --daemon
sleep 5

# BOINC attachment logic
if [ -n "$BOINC_PROJECT_URL" ] && [ -n "$BOINC_ACCOUNT_KEY" ]; then
  echo "Attaching to specific BOINC project: $BOINC_PROJECT_URL"
  boinccmd --project_attach "$BOINC_PROJECT_URL" "$BOINC_ACCOUNT_KEY" || echo "Project attach failed."
elif [ -n "$BOINC_BAM_EMAIL" ] && [ -n "$BOINC_BAM_PASSWORD" ]; then
  echo "Attaching to BAM! account manager..."
  boinccmd --acct_mgr attach https://bam.boincstats.com "$BOINC_BAM_EMAIL" "$BOINC_BAM_PASSWORD" || echo "BAM! attach failed."
elif [ -n "$BOINC_DEFAULT_KEY" ]; then
  echo "No specific project configured. Attaching to World Community Grid by default..."
  boinccmd --project_attach https://www.worldcommunitygrid.org "$BOINC_DEFAULT_KEY" || echo "WCG attach failed."
else
  echo "No BOINC project or account manager configured. BOINC will idle."
fi

echo "Generating synthetic video..."
ffmpeg -y -f lavfi -i testsrc=duration=3600:size=1920x1080:rate=30 test.mp4

echo "Starting CPU load (nice priority)..."
nice -n 19 stress-ng --cpu 0 --cpu-method all --timeout 24h &

echo "Detecting GPU type..."
GPU_INFO=$(lspci | grep -E "VGA|Display" | head -n 1 || true)
echo "GPU_INFO: $GPU_INFO"

if echo "$GPU_INFO" | grep -qi "Intel"; then
  echo "Intel GPU detected — using Quick Sync (QSV)"
  export LIBVA_DRIVER_NAME=iHD
  ffmpeg -stream_loop -1 -i test.mp4 \
    -c:v h264_qsv -b:v 20M -f null - &

elif echo "$GPU_INFO" | grep -qi "AMD"; then
  echo "AMD GPU detected — using VAAPI"
  ffmpeg -stream_loop -1 -i test.mp4 \
    -vf 'format=nv12,hwupload' \
    -c:v h264_vaapi -b:v 20M -f null - &

elif echo "$GPU_INFO" | grep -qi "NVIDIA"; then
  echo "NVIDIA GPU detected — using NVENC"
  ffmpeg -stream_loop -1 -i test.mp4 \
    -c:v h264_nvenc -preset fast -b:v 20M -f null - &

else
  echo "No supported GPU detected — running CPU-only mode."
fi

echo "All load generators running."
wait
