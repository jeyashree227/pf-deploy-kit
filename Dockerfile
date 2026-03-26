#FROM envoyproxy/envoy-dev:30497202ccfed2a8a20a9da9028bd82e934b50a5
FROM envoyproxy/envoy:v1.20.1

RUN apt-get update \
    && apt-get install -y \ 
    curl wget jq python \
    python-pip \
    python-setuptools \
    groff \
    less \
    && pip --no-cache-dir install --upgrade awscli \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /tmp/* /var/tmp/* /var/lib/apt/lists/*

RUN mkdir -p /etc/ssl
ADD start_envoy.sh /start_envoy.sh
ADD envoy.yaml /etc/envoy.yaml

RUN chmod +x /start_envoy.sh

ENTRYPOINT ["/bin/sh"]
EXPOSE 443
CMD ["start_envoy.sh"]
