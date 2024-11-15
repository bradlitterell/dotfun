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
. "${libdir}/Plist.sh"

# MARK: Globals
G_FUNDLE_HWMODELS_URL="http://fun-on-demand-01:9004/hardware_models"
G_FUNDLE_PARAM_ENV_MAP=(
	"RUN_TARGET" "run_target" "string" ""
	"HW_MODEL" "hardware_model" "string" ""
	"BOOTARGS" "boot_args" "string" ""
	"CENTRAL_SCRIPT" "central_script" "string" ""
	"TAGS" "tags" "array" ","
	"EXTRA_EMAIL" "owners" "array" ","
)
G_FUNDLE_JOB_BRANCHES=(
	"branch_funos" "master"
	"branch_funsdk" "master"
	"branch_uboot" "fungible/master"
)
G_LLDB_SERVER="SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver"
G_GDB="/Users/Shared/cross/mips64/bin/mips64-unknown-elf-gdb"

# MARK: Object Fields
F_FUNDLE_BUG_ID=
F_FUNDLE_BRANCH=
F_FUNDLE_PRODUCT=
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

function Fundle._generate_environment()
{
	local f="$1"
	local i=0
	local jid=
	local jdir=

	Plist.init_with_raw "json" '{}'

	# Generate a job identifier and directory. These are kind of dummy values,
	# since they refer to paths in the NFS hierarchy, but we generate them for
	# completeness. And we might want to produce the job ourselves at some
	# point, so might well make it look consistent.
	jid="$(rands 12)"
	jid+="-$(date "+%y-%m-%d-%H-%M")"
	Plist.set_value "job_id" "string" "$jid"

	jdir="/demand/demand/Jobs/$jid"
	Plist.set_value "job_dir" "string" "$jdir"
	Plist.set_value "hardware_version" "Ignored"

	for (( i = 0; i < ${#G_FUNDLE_JOB_BRANCHES[@]}; i += 2 )); do
		local p=${G_FUNDLE_JOB_BRANCHES[$(( i + 0 ))]}
		local b=${G_FUNDLE_JOB_BRANCHES[$(( i + 1 ))]}

		Plist.set_value "$p" "$b"
	done

	for (( i = 0; i < ${#G_FUNDLE_PARAM_ENV_MAP[@]}; i += 4 )); do
		local p=${G_FUNDLE_PARAM_ENV_MAP[$(( i + 0 ))]}
		local e=${G_FUNDLE_PARAM_ENV_MAP[$(( i + 1 ))]}
		local t=${G_FUNDLE_PARAM_ENV_MAP[$(( i + 2 ))]}
		local d=${G_FUNDLE_PARAM_ENV_MAP[$(( i + 3 ))]}
		local v=
		local arr=()

		v=$(FunDotParams.get_value "$p")
		if [ -z "$v" ]; then
			continue
		fi

		case "$t" in
		string)
			Plist.set_value "$e" "string" "$v"
			;;
		array)
			Plist.init_collection "$e" "$t"
			arr=($(CLI.split_specifier_nospace "$d" "$v"))

			for vi in "${#arr[@]}"; do
				Plist.set_value "$e.$j" "string" "$vi"
			done
			;;
		esac
	done

	Plist.get "json" > "$f"
}

function Fundle._generate_debug_tramp()
{
	local platform="$1"
	local flavor="$2"
	local f="$3"
	local script=
	local text=
	local v_lvl=$(CLI.get_verbosity)
	local v_map=(
		"FLAVOR" "$flavor"
		"GDB_WHERE" "$G_GDB"
		"SERVER" "localhost"
		"PORT" "1234"
	)
	local i=0

	if [ "$v_lvl" -ge 2 ]; then
		v_map+=("SET_MINUS_X" "t")
	else
		v_map+=("SET_MINUS_X" "")
	fi

	script="${dotfun}/libexec/debugme_$platform.sh"
	CLI.die_fcheck "$script" "no debug trampoline for platform: $platform"

	text=$(cat "$script")
	for (( i = 0; i < ${#v_map[@]}; i += 2 )); do
		local vn="${v_map[$(( $i + 0 ))]}"
		local vv="${v_map[$(( $i + 1 ))]}"

		vv=$(sed 's/\//\\\//g' <<< "$vv")
		text=$(sed -E "s/\%$vn\%/$vv/g" <<< "$text")
	done

	echo "$text" > "$f"
}

function Fundle._generate_qemu_tramp()
{
	local flavor="$1"
	local f="$2"
	local qemu=
	local script=
	local text=
	local v_lvl=$(CLI.get_verbosity)
	local v_map=(
		"FLAVOR" "$flavor"
		"CHIP" "$(tolower $F_FUNDLE_CHIP)"
	)
	local i=0

	qemu=$(Assembly.get_tool_path "FunSDK" "scripts/qemu-dpu")
	CLI.die_ifz "$qemu" "qemu trampoline not found"

	v_map+=("QEMU_WHERE" "$qemu")
	if [ "$v_lvl" -ge 2 ]; then
		v_map+=("SET_MINUS_X" "t")
	else
		v_map+=("SET_MINUS_X" "")
	fi

	script="${dotfun}/libexec/qemume.sh"
	text=$(cat "$script")
	for (( i = 0; i < ${#v_map[@]}; i += 2 )); do
		local vn="${v_map[$(( $i + 0 ))]}"
		local vv="${v_map[$(( $i + 1 ))]}"

		vv=$(sed 's/\//\\\//g' <<< "$vv")
		text=$(sed -E "s/\%$vn\%/$vv/g" <<< "$text")
	done

	echo "$text" > "$f"
}

# MARK: Meta
function Fundle.run_f1()
{
	local host="$1"
	local rf1=$(CLI.get_boot_state_path "run_f1.py")
	local v_arg=$(CLI.get_verbosity_opt "dv")

	if [ ! -f "$rf1" ]; then
		CLI.command scp $v_arg "$host":/home/robotpal/bin/run_f1.py "$rf1"	
		CLI.die_check $? "copy run_f1"

		CLI.command chmod u+x "$rf1"
		CLI.die_check $? "make run_f1 executable"
	fi

	shift
	CLI.command $rf1 "$@"
}

function Fundle.get_model_descriptor()
{
	local p="$1"
	local p_squish=$(tolower "$p")
	local http_code=
	local js=$(CLI.get_run_state_path "json")
	local m_cnt=
	local i=

	http_code=$(CLI.command curl -s -w '%{response_code}' -o "$js" -X GET \
			-H "Accept: application/json" \
			-H "Content-Type: application/json" \
			"$G_FUNDLE_HWMODELS_URL")
	CLI.debug "got response code: $http_code"

	case "$http_code" in
	200)
		Plist.init_with_file "$js"
		m_cnt=$(Plist.get_count "hardware_models")

		for (( i = 0; i < m_cnt; i++ )); do
			local k_path="hardware_models.$i"
			local v=
			local v_squish=
			local m=

			v=$(Plist.get_value "${k_path}.hardware_model" "string")
			CLI.die_ifz "$v" "failed to query hardware model: $k_path"

			v_squish=$(tolower "$v")
			if [ "$v_squish" != "$p_squish" ]; then
				continue
			fi

			echo "$(Plist.get_value_json "$k_path" "dictionary")"
			break
		done
		;;
	*)
		CLI.err "request failed: $http_code"
		;;
	esac
}

# MARK: Public
function Fundle.init()
{
	local bug_id="$1"
	local branch="$2"
	local product="$3"
	local chip="$4"
	local imgroot="$5"
	local email="$6"
	local bundle=

	# Make the bundle name slightly friendlier to shells.
	F_FUNDLE_NAME=$(tr '-' '_' <<< "$bug_id")
	bundle=$(CLI.get_run_state_path "${F_FUNDLE_NAME}.fundle")

	F_FUNDLE_BUG_ID="$bug_id"
	F_FUNDLE_BRANCH="$branch"
	F_FUNDLE_PRODUCT="$product"
	F_FUNDLE_CHIP="$(toupper "$chip")"
	F_FUNDLE_IMGSRC="$imgroot"
	F_FUNDLE_IMGDIR="$bundle/images"
	F_FUNDLE_EMAIL="$email"
	F_FUNDLE_PATH="$bundle"

	Module.config 0 "Fundle"
	Module.config 1 "name" "$F_FUNDLE_NAME"
	Module.config 1 "bug id" "$F_FUNDLE_BUG_ID"
	Module.config 1 "branch" "$F_FUNDLE_BRANCH"
	Module.config 1 "product" "$F_FUNDLE_PRODUCT"
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

function Fundle.get_root()
{
	echo "$F_FUNDLE_PATH"
}

function Fundle.package()
{
	local platform="$1"
	local which="$2"
	local boot_args="$F_FUNDLE_PATH/boot_args.txt"
	local emails="$F_FUNDLE_PATH/emails.txt"
	local params="$F_FUNDLE_PATH/test.params"
	local env_dot_json="$F_FUNDLE_PATH/env.json"
	local debugme="$F_FUNDLE_PATH/debugme.sh"
	local qemume="$F_FUNDLE_PATH/qemume.sh"
	local cl_argv=
	local script=
	local ar="$(CLI.get_run_state_path "${F_FUNDLE_NAME}.tar.gz")"
	local v_arg=$(CLI.get_verbosity_opt "v")

	if [ -n "$F_FUNDLE_PARAMS" ]; then
		# If we were given a parameters file, then initialize with it and
		# overwrite the fields we know about.
		FunDotParams.init_with_file "$F_FUNDLE_PARAMS"

		FunDotParams.set_value "NAME" "$F_FUNDLE_NAME"
		FunDotParams.set_value "HW_MODEL" "$F_FUNDLE_PRODUCT"
		FunDotParams.set_value "RUN_TARGET" "$F_FUNDLE_CHIP"
		FunDotParams.append_value "EXTRA_EMAIL" "$F_FUNDLE_EMAIL" ","
	else
		FunDotParams.init "$F_FUNDLE_NAME" \
				"$F_FUNDLE_PRODUCT" \
				"$F_FUNDLE_CHIP" \
				"$F_FUNDLE_EMAIL"
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

	Fundle._generate_environment "$env_dot_json"

	case "$platform" in
	qemu|posix)
		Fundle._generate_debug_tramp "$platform" "$which" "$debugme"
		CLI.command chmod u+x "$debugme"

		if [ "$platform" = "qemu" ]; then
			Fundle._generate_qemu_tramp "$which" "$qemume"
			CLI.command chmod u+x "$qemume"
		fi
		;;
	*)
		;;
	esac

	FunDotParams.write "$params"

	CLI.command tar -cz${v_arg}f "$ar" -C "$F_FUNDLE_PATH" .
	F_FUNDLE_AR="$ar"
}

function Fundle.run()
{
	local platform="$1"
	local opts="$2"
	local debug=
	local dpc=
	local wait=
	local image=
	local argv=()
	local boot_args=()

	debug=$(grep -oE 'debug' <<< "$opts")
	dpc=$(grep -oE 'dpc' <<< "$opts")

	image=$(Assembly.get_image "FunOS" "rich")
	CLI.die_ifz "$image" "no symbol-rich FunOS image to run"

	# Boot args are delimited by spaces, so we can safely capture this in an
	# array.
	boot_args=($(FunDotParams.get_value "BOOTARGS"))
	case "$platform" in
	posix)
		local need_dpc_server="$dpc"

		# We don't have to do anything special for DPC in POSIX, since the
		# presence of the boot-arg will set up the TCP listener.
		if [ -n "$debug" ]; then
			local xcode=
			local debugserver=

			xcode=$(xcode-select -p)
			CLI.die_ifz "$xcode" "no Xcode installation for posix debugging"

			debugserver="$xcode/../$G_LLDB_SERVER"
			debugserver=$(realpath "$debugserver")
			CLI.die_fcheck "$debugserver" "no debugserver found: $debugserver"

			argv+=("$debugserver")
			argv+=("localhost:4321")
		fi

		argv+=("$image")
		for ba in ${boot_args[@]}; do
			# If the boot-args already have '--dpc-server', then we don't need
			# to add it if the user requested a DPC server at the command line.
			if [ "$ba" = "--dpc-server" ]; then
				need_dpc_server=
			fi

			argv+=("$ba")
		done

		if [ -n "$need_dpc_server" ]; then
			argv+=("--dpc-server")
		fi

		CLI.command "${argv[@]}"
		;;
	qemu)
		local delim="--"

		argv+=("scripts/qemu-dpu")
		argv+=("--machine" "$(tolower $F_FUNDLE_CHIP)")

		# If we are running through Qemu, we have to set up the DPC uart in
		# Qemu with the -U option.
		if [ -n "$dpc" ]; then
			argv+=("-U")
		fi

		if [ -n "$debug" ]; then
			argv+=("-s")
			argv+=("-W")
		fi
		
		argv+=("$image")
		for ba in ${boot_args[@]}; do
			if [ -n "$delim" ]; then
				argv+=("$delim")
				delim=
			fi

			argv+=("$ba")
		done

		Assembly.run_tool "FunSDK" "${argv[@]}"
		;;
	*)
		CLI.die "unsupported platform: $platform"
		;;
	esac
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
