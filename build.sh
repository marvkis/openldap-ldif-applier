#!/bin/bash
set -e
#docker build -t marvkis/openldap-ldif-applier .
#docker push marvkis/openldap-ldif-applier
docker buildx build --platform linux/amd64 --push -t marvkis/openldap-ldif-applier .
