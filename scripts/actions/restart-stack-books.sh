#!/usr/bin/env bash
# Wrapper: restart the books compose stack.
STACK_NAME=books exec "$(dirname "$0")/restart-stack.sh"
