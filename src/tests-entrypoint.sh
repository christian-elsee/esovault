#!/bin/sh
## Bootstrap alpine environment used to run tap-compliant tests
set -eu

## main
logger -sp DEBUG -- "Enter" :: "cmd=$*"

apk add --update-cache perl-utils
sh -xc "$@"
