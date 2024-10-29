#!/bin/bash -O extglob

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	set -x
fi

SERVER='%SERVER%'
PORT='%PORT%'
FLAVOR='%FLAVOR%'

mydir="$(dirname "${BASH_SOURCE[0]}")"
mydir="$(realpath "$mydir")"

cd "$mydir"
xcrun -sdk macosx lldb \
		-O "target create images/FunOS/$FLAVOR" \
		-O "gdb-remote $SERVER:$PORT"

