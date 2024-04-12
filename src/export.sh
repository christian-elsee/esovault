#!/bin/bash
## Exports environment variables, defined at a given path,
## to a given commands subshell. Environment variables are
## defined by the given paths' files, which follow a
## key=value convention, by using file name and data, respectively.
#$ ./export.sh $path $command [$args]
#$ tee dist/env/FU <<<'BAR' &&  \
#$ ./export.sh dist/env envsubst < <(echo 'hello $FU')
set -euo pipefail
2>/dev/null >&3 || exec 3>/dev/null

## env
path=${1?path} ;shift
cmd=${@:-printenv}

## main
logger -sp DEBUG -- "Enter" \
  :: "path=$path" \
     "command=$cmd" 2>&3

## declare export variables
payload=$(
  ls -1 "$path" \
    | grep -E -- '^[A-Z_][A-Z0-9_]+$' \
    | xargs -I@ -- printf "export @\n" \

  ## define variables w/bound value
  ls -1 "$path" \
    | xargs -n1 -- sh -c \
      'printf "%s=\$(cat %s)\n" \
        "$2"    \
        "$1/$2" \
      ' _ "$path"
)
logger -sp INFO -- "Source payload" \
  :: "path=$path"   \
     "command=$cmd" \
  :: "$(echo "$payload" | base64 | tr -d \\n)" \
2>&3

eval "$payload"
exec sh -c "$cmd" "$0"
