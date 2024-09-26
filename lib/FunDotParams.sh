#!/bin/bash -O extglob

# MARK: Module preamble
# Executables must initialize the $sharedir variable based on their own
# locations. The executable preamble goes like this:
#
#     mydir="$(dirname $0)"
#     pushd "$mydir/.." > /dev/null; dotfiles="$(pwd)"; popd > /dev/null
#     libdir="${dotfiles}/lib"
#     bindir="${dotfiles}/bin"
#     libexecdir="${dotfiles}/libexec"
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
	echo "library modules cannot be executed directly" >&2
	exit 1
fi

if [ -z "$libdir" ]; then
	echo "library modules must be initialized by sourcer" >&2
	exit 1
fi

# MARK: Imports
. "${libdir}/Lib.sh"
. "${libdir}/Module.sh"

# MARK: Globals
# RUN_TARGET is where the job should run, and it can refer to an actual piece of
# silicon or an emulation environment like "palladium". HW_MODEL is the product
# enclosure, which can also be an actual piece of silicon like "S2F1" or 
# "F1Network". If it's just a chip, it indicates that the target is a random
# enclosure that has that chip in it. For these purposes, we'll just always make
# them the same.
G_FUNDOTPARAMS_REQUIRED=(
	"NAME" "n/a"
	"AT" "skip"
	"HW_MODEL" "F1"
	"PRIORITY" "normal_priority"
	"RUN_TARGET" "F1"
	"MAX_DURATION" "10"
	"RUN_MODE" "Batch"
)

# MARK: Fields
F_FUNDOTPARAMS_PARAMS=()

# MARK: Internal
function FunDotParams._assert_required()
{
	local i=0

	for (( i = 0; i < ${#G_FUNDOTPARAMS_REQUIRED}; i += 2 )); do
		local ki=${G_FUNDOTPARAMS_REQUIRED[$(( i + 0 ))]}
		local vi=${G_FUNDOTPARAMS_REQUIRED[$(( i + 1 ))]}
		local v=

		v=$(FunDotParams.get_value "$ki")
		CLI.die_ifz "$v" "required parameter missing: $ki"
	done
}

# MARK: Public
function FunDotParams.init()
{
	local name="$1"
	local chip="$2"
	local email="$3"
	local i=0

	F_FUNDOTPARAMS_PARAMS=()
	for (( i = 0; i < ${#G_FUNDOTPARAMS_REQUIRED}; i += 2 )); do
		local ki=${G_FUNDOTPARAMS_REQUIRED[$(( i + 0 ))]}
		local vi=${G_FUNDOTPARAMS_REQUIRED[$(( i + 1 ))]}

		F_FUNDOTPARAMS_PARAMS+=("$ki" "$vi")
	done

	FunDotParams.set_value "NAME" "$name"
	FunDotParams.set_value "HW_MODEL" "$chip"
	FunDotParams.set_value "RUN_TARGET" "$chip"
	FunDotParams.set_value "EXTRA_EMAIL" "$email"

	Module.config 0 "FunDotParams"
	Module.config 1 "name" "$name"
	Module.config 1 "hw model" "$chip"
	Module.config 1 "run target" "$chip"
	Module.config 1 "creator" "$email"
}

function FunDotParams.init_with_file()
{
	local f="$1"

	F_FUNDOTPARAMS_PARAMS=()
	Module.config 0 "FunDotParams"

	while read -r l; do
		local k=
		local v=

		if [[ "$l" =~ ^# ]]; then
			continue
		fi

		case "$l" in
		\#*|+([[:space:]])|'')
			# Skip comments and lines that are blank or all whitespace.
			continue
			;;
		esac

		CLI.debug "parsing line: $l"
		k="${l%%:*}"
		v="${l#*:}"

		# Trim leading and trailing whitespace for the key and value.
		CLI.debug "k = $k, v = $v"
		k="$(strclean "$k")"
		v="$(strclean "$v")"

		# Keys have to be all-caps.
		if [[ ! "$k" =~ [A-Z_]+ ]]; then
			CLI.die "invalid key: $k"
		fi

		Module.config 1 "$k" "$v"
		F_FUNDOTPARAMS_PARAMS+=("$k" "$v")
	done < "$f"
}

function FunDotParams.set_value()
{
	local k="$1"
	local v="$2"
	local i=0

	for (( i = 0; i < ${#F_FUNDOTPARAMS_PARAMS[@]}; i += 2 )); do
		local ki=${F_FUNDOTPARAMS_PARAMS[$(( i + 0 ))]}
		local vi=${F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]}

		if [ "$ki" = "$k" ]; then
			F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]="$v"
			return
		fi
	done

	F_FUNDOTPARAMS_PARAMS+=("$k" "$v")
}

function FunDotParams.append_value()
{
	local k="$1"
	local v="$2"
	local d="$(initdefault "$3" ' ')"
	local i=0

	for (( i = 0; i < ${#F_FUNDOTPARAMS_PARAMS[@]}; i += 2 )); do
		local ki=${F_FUNDOTPARAMS_PARAMS[$(( i + 0 ))]}
		local vi=${F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]}

		if [ "$vi" = "" ]; then
			d=
		fi

		if [ "$ki" = "$k" ]; then
			F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]="$vi$d$v"
			return
		fi
	done

	F_FUNDOTPARAMS_PARAMS+=("$k" "$v")
}

function FunDotParams.get_value()
{
	local k="$1"
	local i=0

	for (( i = 0; i < ${#F_FUNDOTPARAMS_PARAMS[@]}; i += 2 )); do
		local ki=${F_FUNDOTPARAMS_PARAMS[$(( i + 0 ))]}
		local vi=${F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]}

		if [ "$ki" = "$k" ]; then
			echo "$vi"
			return
		fi
	done
}

function FunDotParams.write()
{
	local f="$1"
	local i=0

	# Don't write out if we're missing required parameters.
	FunDotParams._assert_required
	Module.config 0 "FunDotParams [write]"

	for (( i = 0; i < ${#F_FUNDOTPARAMS_PARAMS[@]}; i += 2 )); do
		local ki=${F_FUNDOTPARAMS_PARAMS[$(( i + 0 ))]}
		local vi=${F_FUNDOTPARAMS_PARAMS[$(( i + 1 ))]}

		# Refuse to write out blank parameters.
		CLI.die_ifz "$vi" "invalid value for param: $ki"
		Module.config 1 "$k" "$v"
		echo "$ki : $vi" >> "$f"
	done
}
