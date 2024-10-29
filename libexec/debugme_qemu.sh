#!/bin/bash -O extglob

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	set -x
fi

GDB_WHERE='%GDB_WHERE%'
SERVER='%SERVER%'
PORT='%PORT%'
FLAVOR='%FLAVOR%'

mydir="$(dirname "${BASH_SOURCE[0]}")"
mydir="$(realpath "$mydir")"

cd "$mydir"
"$GDB_WHERE" --ex "target remote $SERVER:$PORT" "images/FunOS/$FLAVOR"
