FROM alpine:latest

# LABEL about the custom image
LABEL maintainer="Christian Niessner <marvkis@users.noreply.github.com>"
LABEL version="0.1"
LABEL description="This container executes a job to update openldap to match the ldif's."
LABEL last_changed="2021-12-10"

ENV  RUN_DEPS="openldap-clients openldap bash"

RUN apk add $RUN_DEPS

RUN rm /var/cache/apk/* && \
    mkdir -p /var/empty/var/run/ && \
    chmod 755 -R /var/empty/var/run

RUN mkdir -p /app/bin && mkdir -p /app/lib && mkdir -p /app/ldifs
ADD https://github.com/nxadm/ldifdiff/releases/download/v0.2.0/ldifdiff-linuxamd64 /app/bin/ldifdiff
ADD https://github.com/osixia/docker-light-baseimage/raw/master/image/tool/log-helper /app/bin/log-helper

USER root
COPY process-ldifs.sh /app/process-ldifs.sh
RUN chmod 755 /app/process-ldifs.sh /app/bin/*

#USER pdns
ENTRYPOINT ["/app/process-ldifs.sh"]
CMD ["app:start"]
