#!/usr/bin/env bash
# Thin wrapper so the protocol documents one entry point.
exec node "$(dirname "$0")/check_msg.js" "$@"
