#!/bin/bash -O extglob

set -e
SET_MINUS_X='%SET_MINUS_X%'
if [ -n "$SET_MINUS_X" ]; then
	echo "executing on host: $(hostname)" >&2
	set -x
fi

AR_BASE='%AR_BASE%'
AR='%AR%'
FLAVOR='%FLAVOR%'

OTHER_IMAGES=(
	"FunSDK" "gzip"
	"FunTest" "gzip"
	"FunOS" "elf"
)

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

# Collect our supporting cast of images. run_f1 accepts an --other-images
# option, but Python's argparse is kind of shady with this. It permits stuff to
# be shortened, and so it recognizes --other-image (singular) as the same
# option. But it just does a store of the last value it encounters because
# run_f1 doesn't use argparse's builtin support for collecting multiple
# instances of a single option together. So we have to assemble the comma-
# separated list to get the behavior we want; we can't just pass --other-image
# multiple times.
set +e
comma=
other_images=
for (( i = 0; i < ${#OTHER_IMAGES[@]}; i += 2 )); do
	oii=${OTHER_IMAGES[$(( i + 0 ))]}
	ni=${OTHER_IMAGES[$(( i + 1 ))]}
	p="images/$oii/$ni"
	f=

	if [ ! -f "$p" ]; then
		continue
	fi

	f=$(readlink "$p")
	if [ ! -n "$f" ]; then
		continue
	fi

	# Hack for some tests that expect a stripped, unsigned ELF image to be
	# present in the job directory with the ".elf" suffix. I'm not sure where
	# this came from, but it's only in the ISSU tests, and nothing in the FunOS
	# makefiles appears to produce this. I think the author of those tests
	# didn't actually understand what each image was and was just trying to
	# avoid using the signed image, since it had certificates and a header.
	#
	# We create a hard link to the target file of the "elf" symlink that has the
	# appropriate suffix since run_f1.py cannot deal with symlinks properly.
	if [ "$ni" = "elf" ]; then
		issu_hack="images/$oii/$f.elf"
		ln "images/$oii/$f" "$issu_hack"
		f+=".elf"
	fi

	other_images+="${comma}${d}/images/$oii/${f}"
	comma=','
done
set -e

if [ -n "$other_images" ]; then
	other_images=" --other-images $other_images"
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
run_f1+="$other_images"
run_f1+=" $d/images/FunOS/$image"

# The job identifier is written to stderr, so redirect it to stdout for capture
# by the Fundle module.
eval "$run_f1" 2>&1
