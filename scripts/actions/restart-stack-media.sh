#!/usr/bin/env bash
# Wrapper: restart the media-core compose stack (Plex + Arr suite).
STACK_NAME=media-core exec "$(dirname "$0")/restart-stack.sh"
