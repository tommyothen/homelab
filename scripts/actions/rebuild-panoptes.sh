#!/usr/bin/env bash
# Wrapper: nixos-rebuild switch on Panoptes.
REBUILD_TARGET=panoptes exec "$(dirname "$0")/rebuild-host.sh"
