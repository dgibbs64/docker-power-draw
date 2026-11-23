FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update \
  && apt-get install -y \
    boinc-client \
    ca-certificates \
    curl \
    ffmpeg \
    intel-media-va-driver-non-free \
    mesa-va-drivers \
    pciutils \
    stress-ng \
    vainfo \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Working directory
WORKDIR /loadburner

# Copy startup script
COPY start.sh /loadburner/start.sh
RUN chmod +x /loadburner/start.sh

# BOINC RPC port (optional)
EXPOSE 31416

# Default command
CMD ["/loadburner/start.sh"]
