#!/bin/bash
# First-boot script for backend instances. backend-deploy.yml fills in the
# @...@ placeholders and stores the result as the UserData of a new launch
# template version, so every instance launched from that version runs exactly
# one release. Instances are never changed in place; a new release replaces
# them through an instance refresh.
#
# The AMI provides Docker and AWS CLI v2, and sets Docker's shutdown-timeout
# above the container stop timeout below, so containers stop cleanly when the
# instance is terminated.
set -euo pipefail

IMAGE_URI='@IMAGE_URI@'
APP_VERSION='@APP_VERSION@'
ENVIRONMENT='@ENVIRONMENT@'

APP_PORT=8080
ENV_FILE=/opt/backend/app.env
PARAM_PATH="/web-product/backend/$ENVIRONMENT/"
LOG_GROUP="/web-product/backend/$ENVIRONMENT"

mkdir -p /opt/backend

# Configuration and secrets live in SSM Parameter Store, never in GitHub or in
# the launch template. Every parameter under PARAM_PATH becomes an env var.
tmp=$(mktemp "$ENV_FILE.XXXXXX")
aws ssm get-parameters-by-path \
  --path "$PARAM_PATH" --recursive --with-decryption \
  --query 'Parameters[].[Name,Value]' --output text |
  while IFS=$'\t' read -r name value; do
    printf '%s=%s\n' "${name##*/}" "$value"
  done >"$tmp"
mv "$tmp" "$ENV_FILE"

registry=${IMAGE_URI%%/*}
region=$(cut -d. -f4 <<<"$registry")
aws ecr get-login-password --region "$region" |
  docker login --username AWS --password-stdin "$registry"

docker pull "$IMAGE_URI"

# The ALB only sends traffic once /healthz passes its health check. On
# termination the Auto Scaling group deregisters the instance and waits for
# the target group's deregistration delay before shutting it down; SIGTERM
# then gives the app --stop-timeout seconds to finish any remaining requests.
docker run --detach \
  --name backend \
  --restart unless-stopped \
  --stop-timeout 30 \
  --publish "$APP_PORT:$APP_PORT" \
  --env-file "$ENV_FILE" \
  --env "PORT=$APP_PORT" \
  --env "APP_VERSION=$APP_VERSION" \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --log-driver awslogs \
  --log-opt "awslogs-group=$LOG_GROUP" \
  --log-opt "awslogs-stream=$(hostname)/$APP_VERSION" \
  "$IMAGE_URI"
