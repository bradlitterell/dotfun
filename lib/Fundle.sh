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

# MARK: Object Fields
F_FUNDLE_BUG_ID=
F_FUNDLE_BRANCH=
F_FUNDLE_CHIP=
F_FUNDLE_PATH=
F_FUNDLE_NAME=
F_FUNDLE_IMGDIR=
F_FUNDLE_IMGSRC=
F_FUNDLE_PARAMS=
F_FUNDLE_BOOT_ARGS=()
F_FUNDLE_EMAIL=
F_FUNDLE_EXTRA_EMAILS=()
F_FUNDLE_DURATION=
F_FUNDLE_AR=

# MARK: Internal
function Fundle._scriptify()
{
	local flavor="$1"
	local script="${dotfun}/libexec/fodit.sh"
	local text=$(cat "$script")
	local v_lvl=$(CLI.get_verbosity)
	local v_map=(
		"AR_BASE" "${F_FUNDLE_NAME}"
		"AR" "${F_FUNDLE_NAME}.tar.gz"
		"FLAVOR" "$flavor"
	)
	local i=0

	if [ "$v_lvl" -ge 2 ]; then
		v_map+=("SET_MINUS_X" "t")
	else
		v_map+=("SET_MINUS_X" "")
	fi

	for (( i = 0; i < ${#v_map[@]}; i += 2 )); do
		local vn="${v_map[$(( $i + 0 ))]}"
		local vv="${v_map[$(( $i + 1 ))]}"

		vv=$(sed 's/\//\\\//g' <<< "$vv")
		text=$(sed -E "s/\%$vn\%/$vv/g" <<< "$text")
	done

	echo "$text"
}

# MARK: Public
function Fundle.init()
{
	local bug_id="$1"
	local branch="$2"
	local chip="$3"
	local imgroot="$4"
	local email="$5"
	local bundle=

	# Make the bundle name slightly friendlier to shells.
	F_FUNDLE_NAME=$(tr '-' '_' <<< "$bug_id")
	bundle=$(CLI.get_run_state_path "${F_FUNDLE_NAME}.fundle")

	F_FUNDLE_BUG_ID="$bug_id"
	F_FUNDLE_BRANCH="$branch"
	F_FUNDLE_CHIP="$(toupper "$chip")"
	F_FUNDLE_IMGSRC="$imgroot"
	F_FUNDLE_IMGDIR="$bundle/images"
	F_FUNDLE_EMAIL="$email"
	F_FUNDLE_PATH="$bundle"

	Module.config 0 "Fundle"
	Module.config 1 "name" "$F_FUNDLE_NAME"
	Module.config 1 "bug id" "$F_FUNDLE_BUG_ID"
	Module.config 1 "branch" "$F_FUNDLE_BRANCH"
	Module.config 1 "chip" "$F_FUNDLE_CHIP"
	Module.config 1 "image source" "$F_FUNDLE_IMGSRC"
	Module.config 1 "image directory" "$F_FUNDLE_IMGDIR"
	Module.config 1 "creator" "$F_FUNDLE_EMAIL"
	Module.config 1 "path" "$F_FUNDLE_PATH"

	CLI.command mkdir -p "$F_FUNDLE_IMGDIR"
}

function Fundle.set_params()
{
	local f="$1"
	F_FUNDLE_PARAMS="$f"
}

function Fundle.add_boot_arg()
{
	local arg="$1"
	F_FUNDLE_BOOT_ARGS+=("$arg")
}

function Fundle.add_email()
{
	local em="$1"
	F_FUNDLE_EXTRA_EMAILS+=("$em")
}

function Fundle.set_duration()
{
	local d="$1"
	F_FUNDLE_DURATION="$d"
}

function Fundle.package()
{
	local which="$1"
	local boot_args="$F_FUNDLE_PATH/boot_args.txt"
	local emails="$F_FUNDLE_PATH/emails.txt"
	local params="$F_FUNDLE_PATH/test.params"
	local script=
	local ar="$(CLI.get_run_state_path "${F_FUNDLE_NAME}.tar.gz")"
	local v_arg=$(CLI.get_verbosity_opt "v")

	if [ -n "$F_FUNDLE_PARAMS" ]; then
		# If we were given a parameters file, then initialize with it and
		# overwrite the fields we know about.
		FunDotParams.init_with_file "$F_FUNDLE_PARAMS"

		FunDotParams.set_value "NAME" "$F_FUNDLE_NAME"
		FunDotParams.set_value "HW_MODEL" "$F_FUNDLE_CHIP"
		FunDotParams.set_value "RUN_TARGET" "$F_FUNDLE_CHIP"
		FunDotParams.append_value "EXTRA_EMAIL" "$F_FUNDLE_EMAIL" ","
	else
		FunDotParams.init "$F_FUNDLE_NAME" "$F_FUNDLE_CHIP" "$F_FUNDLE_EMAIL"
	fi

	if [ -n "$F_FUNDLE_DURATION" ]; then
		FunDotParams.set_value "MAX_DURATION" "$F_FUNDLE_DURATION"
	fi

	for ba in ${F_FUNDLE_BOOT_ARGS[@]}; do
		FunDotParams.append_value "BOOTARGS" "$ba"
		echo "$ba" >> "$boot_args"
	done

	for em in ${F_FUNDLE_EXTRA_EMAILS[@]}; do
		FunDotParams.append_value "EXTRA_EMAIL" "$em" ","
		echo "$em" >> "$emails"
	done

	cp_clone -R "$F_FUNDLE_IMGSRC/" "$F_FUNDLE_IMGDIR/"
	echo "$F_FUNDLE_BUG_ID" > "$F_FUNDLE_PATH/bug.txt"
	echo "$F_FUNDLE_BRANCH" > "$F_FUNDLE_PATH/branch.txt"

	script=$(Fundle._scriptify "$which")
	echo "$script" > "$F_FUNDLE_PATH/fodit.sh"
	FunDotParams.write "$params"

	CLI.command tar -cz${v_arg}f "$ar" -C "$F_FUNDLE_PATH" .
	F_FUNDLE_AR="$ar"
}

function Fundle.submit()
{
	local host="$1"
	local fodit="$F_FUNDLE_PATH/fodit.sh"
	local v_arg=$(CLI.get_verbosity_opt "dv")
	local out=
	local job=

	CLI.command scp $v_arg "$F_FUNDLE_AR" "$host":~/
	out=$(CLI.command ssh $v_arg "$host" /bin/bash < "$fodit")
	job=$(grep 'Enqueued as job ' <<< "$out")
	job=$(strip_prefix "$job" 'Enqueued as job ')
	job=$(grep -oE '^[0-9]+' <<< "$job")

	CLI.die_ifz "$job" "job submission failed"
	echo "http://palladium-jobs.fungible.local/job/$job"
}
