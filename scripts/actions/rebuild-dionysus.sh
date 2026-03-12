#!/usr/bin/env bash
# Wrapper: nixos-rebuild switch on Dionysus.
REBUILD_TARGET=dionysus exec "$(dirname "$0")/rebuild-host.sh"
