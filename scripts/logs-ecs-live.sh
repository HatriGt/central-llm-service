#!/bin/bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINCE="${SINCE:-1m}"

SINCE="${SINCE}" "${DIR}/tail-logs.sh" ecs --follow

