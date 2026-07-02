#!/bin/sh
set -e

CONFIG="${UPLINK_CONFIG:-/uplink/config.json}"

if [ ! -f "$CONFIG" ]; then
  echo "error: config file not found at $CONFIG" >&2
  echo "  mount it with: docker run -v ./config.json:$CONFIG ..." >&2
  exit 1
fi

cd /uplink

echo "generating nginx config from $CONFIG..."
luajit generate.lua

echo "validating nginx config..."
openresty -p /uplink -c nginx/nginx.conf -t

echo "starting openresty..."
exec openresty -p /uplink -c nginx/nginx.conf -g "daemon off;"
