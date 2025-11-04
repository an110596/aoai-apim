FROM mcr.microsoft.com/azure-cli:azurelinux3.0
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         git \
         ca-certificates \
    && rm -rf /var/lib/apt/lists/*
