#!/usr/bin/env bash
# Wrapper: restart the personal compose stack.
STACK_NAME=personal exec "$(dirname "$0")/restart-stack.sh"
