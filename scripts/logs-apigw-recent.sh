#!/bin/bash

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINCE="${SINCE:-30m}"

SINCE="${SINCE}" "${DIR}/tail-logs.sh" apigw

