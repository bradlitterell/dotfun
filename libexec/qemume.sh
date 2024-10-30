#!/bin/bash -O extglob

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	set -x
fi

QEMU_WHERE='%QEMU_WHERE%'
FLAVOR='%FLAVOR%'
CHIP='%CHIP%'

mydir="$(dirname "${BASH_SOURCE[0]}")"
mydir="$(realpath "$mydir")"

cd "$mydir"
"$QEMU_WHERE" --machine "$CHIP" "images/FunOS/$FLAVOR" -- "$@"
