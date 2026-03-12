#!/usr/bin/env bash
# Wrapper: restart the paperless compose stack.
STACK_NAME=paperless exec "$(dirname "$0")/restart-stack.sh"
