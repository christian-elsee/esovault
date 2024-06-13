#!/bin/bash
## Vault CLI wrapper around available vault-0 instance in kubernetes
## by encapsulating kubectl exec yada yada vault-0 -- yada
set -euo pipefail
2>/dev/null >&3 || exec 3>/dev/null

## env
: ${NS?}

pod=${1?pod} ;shift
: ${@?argv}

## main
logger -sp DEBUG -- "Enter" \
  :: "pod=$pod" \
  :: "namespace=$NS" \
  :: "$( echo $@ | base64 | tr -d \\n )" 2>&3

kubectl -n $NS exec -i "$pod" -- vault "$@"
