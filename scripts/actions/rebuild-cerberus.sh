#!/usr/bin/env bash
# Wrapper: nixos-rebuild switch on Cerberus.
REBUILD_TARGET=cerberus exec "$(dirname "$0")/rebuild-host.sh"
