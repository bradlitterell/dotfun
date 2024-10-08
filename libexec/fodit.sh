#!/bin/bash -O extglob

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	set -x
fi

AR_BASE='%AR_BASE%'
AR='%AR%'
FLAVOR='%FLAVOR%'

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

# run_f1.py cannot follow symlinks for the image.
image=$(readlink "images/FunOS/$FLAVOR")
if [ -z "$image" ]; then
	echo "failed to read image link: images/FunOS/$FLAVOR" >&2
	exit 1
fi

# If FunTest is included in the bundle, then make sure we tell that to run_f1.
tests=$(readlink "images/FunTest/gzip")
if [ -n "$tests" ]; then
	tests=" --other-image $d/images/FunTest/$tests"
fi

v_arg=
if [ -n "$SET_MINUS_X" ]; then
	v_arg="-v"
fi

# fun-on-demand-02 only has Python 2.6, so we need to look for both versions of
# pip.
whichpip=
pips=(
	"pip3"
	"pip"
)

set +e
for p in ${pips[@]}; do
	which "$p"
	if [ $? -eq 0 ]; then
		whichpip="$p"
		break
	fi
done
set -e

if [ -z "$whichpip" ]; then
	echo "no pip found" >&2
	exit 1
fi

# This dependency isn't present in the system-wide Python, so we need to install
# it. If it's already installed, pip will just exit successfully.
$whichpip install $v_arg --user requests

run_f1='~robotpal/bin/run_f1.py'
run_f1+=" --robot"
run_f1+=" --params-file test.params"
run_f1+="$tests"
run_f1+=" $d/images/FunOS/$image"

# The job identifier is written to stderr, so redirect it to stdout for capture
# by the Fundle module.
eval "$run_f1" 2>&1
