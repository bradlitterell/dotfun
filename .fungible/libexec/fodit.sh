#!/bin/bash

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	set -x
fi

AR_BASE='%AR_BASE%'
AR='%AR%'
FLAVOR='%FLAVOR%'
CHIP='%CHIP%'

# Create a temporary directory and move the archive to it so that it can be
# easily cleaned up by periodic scripts.
b=$(mktemp -d "/tmp/${AR_BASE}.XXXXXX")
d="$b/fundle"
mkdir -p "$d"
mv "./$AR" "$b/"

# Now expand the archive into the bundle content directory and assemble our
# run_f1 invocation.
cd "$d"
tar -xvzf "$b/$AR"

# Read the email addresses and smash them together with commas.
comma=
emails=
while IFS= read -r l; do
	emails+="${comma}${l}"
	comma=','
done < "emails.txt"

# Now read the boot-args and slap them on to the end of the run_f1 invocation.
space=
boot_args=
while IFS= read -r l; do
	boot_args+="${space}${l}"
	space=' '
done < "boot_args.txt"

bug=$(cat "bug.txt")

# run_f1.py cannot follow symlinks for the image.
image=$(readlink "images/FunOS/$FLAVOR")
if [ -z "$image" ]; then
	echo "failed to read image link: images/FunOS/$FLAVOR" >&2
	exit 1
fi

v_arg=
if [ -n "$SET_MINUS_X" ]; then
	v_arg="-v"
fi

# This dependency isn't present in the system-wide Python, so we need to install
# it. If it's already installed, pip will just exit successfully.
pip3 install $v_arg --user requests

# run_f1.py uses case-sensitive matching for hardware models, so find the right
# one.
models=$(~robotpal/bin/run_f1.py --list-hardware-models --robot)
model=$(grep -Eio "^$CHIP " <<< "$models")
model=$(head -n1 <<< "$model")
model=$(tr -d ' ' <<< "$model")

run_f1='~robotpal/bin/run_f1.py'
run_f1+=" --robot"
run_f1+=" --hardware-model $model"
run_f1+=" --email $emails"
run_f1+=" --note $bug"
run_f1+=" $d/images/FunOS/$image"
run_f1+=" --"
run_f1+=" $boot_args"

# The job identifier is written to stderr, so redirect it to stdout for capture
# by the Fundle module.
eval "$run_f1" 2>&1
