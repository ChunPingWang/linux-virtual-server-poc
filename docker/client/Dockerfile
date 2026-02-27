FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y -qq curl apache2-utils net-tools tcpdump jq iproute2 iputils-ping bc && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY test-scripts/ /usr/local/bin/

RUN chmod +x /usr/local/bin/test-*.sh

# Keep container running
CMD ["sleep", "infinity"]
