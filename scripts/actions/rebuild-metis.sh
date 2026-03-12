#!/usr/bin/env bash
# Wrapper: nixos-rebuild switch on Metis.
REBUILD_TARGET=metis exec "$(dirname "$0")/rebuild-host.sh"
