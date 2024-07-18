#!/bin/bash

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
# Note that we can only safely import modules that don't have any state. See the
# comment in FunJira.init.
. "${libdir}/Lib.sh"
. "${libdir}/Module.sh"

# MARK: Globals
FUNJIRA_KEYCHAIN_IDENTIFIER="local.fungible.jira.dotfiles"
FUNJIRA_CONFIG="bug.FunJira"

# MARK: Module State
FUNJIRA_API="http://jira.fungible.local:8080/rest/api/2"
FUNJIRA_PROJECT=
FUNJIRA_NUMBER=
FUNJIRA_USERNAME=
FUNJIRA_KEY=
FUNJIRA_ISSUE=
FUNJIRA_UPDATE_FIELDS=()
FUNJIRA_UPDATE_PROPERTIES=()
FUNJIRA_UPDATE_TRANSITIONS=()
FUNJIRA_QUERY_FIELDS=()
FUNJIRA_QUERY_PROPERTIES=()

# MARK: Internal
function FunJira._get_password()
{
	# Fungible's Jira doesn't appear to support personal access tokens, so we
	# have to stash the password in the Keychain and use basic auth.
	Keychain.init "$FUNJIRA_KEYCHAIN_IDENTIFIER" "jira" "$FUNJIRA_USERNAME"
	Keychain.get_password_or_prompt
}

function FunJira._api()
{
	local which="$1"
	local call="$2"
	local data="$3"
	local url="$FUNJIRA_API/$call"
	local auth=
	local pw=
	local r=
	local http_status=
	local message=

	pw=$(FunJira._get_password)
	CLI.die_ifz $? "failed to get jira password for $FUNJIRA_USERNAME"

	auth="${FUNJIRA_USERNAME}:$pw"
	if [ -n "$data" ]; then
		r=$(CLI.command curl -s -X "$which" \
				-u "$auth" \
				-H 'Accept: application/json' \
				-H "Content-Type: application/json" \
				-d "$data" \
				"$url")
	else
		r=$(CLI.command curl -s -X "$which" \
				-u "$auth" \
				-H 'Accept: application/json' \
				-H "Content-Type: application/json" \
				"$url")
	fi

	Plist.init_with_raw "json" "$r"
	http_status=$(Plist.get_value "status-code" "integer" "200")
	case "$http_status" in
	20[0-9])
		message=$(Plist.get_value "errorMessages.0" "string")
		if [ -n "$message" ]; then
			# Jira uses http status codes except when it doesn't.
			CLI.die "api call failed with response: $r"
		fi

		if [ "$which" = "GET" ]; then
			echo "$r"
		fi
		;;
	30[0-9])
		CLI.die "unexpected redirect: $http_status"
		;;
	40[0-9])
		message=$(Plist.get_value "message" "string")
		CLI.die "api call failed with $http_status: $message"
		;;
	*)
		CLI.die "api call failed with response: $r"
		;;
	esac
}

function FunJira._to_jira_title()
{
	local v="$1"
	local js_jira="$2"

	Plist.init_with_raw "json" "$js_jira"
	Plist.set_value "fields.summary" "string" "$v"
	Plist.get "json"
}

function FunJira._from_jira_title()
{
	local js_jira="$1"
	local js="$2"
	local v=

	Plist.init_with_raw "json" "$js_jira"
	v=$(Plist.get_value "fields.summary" "string")
	CLI.die_ifz "$v" "failed to get summary from json response: $js_jira"

	Plist.init_with_raw "json" "$js"
	Plist.set_value "Title" "string" "$v"
	Plist.get "json"
}

function FunJira._to_jira_status()
{
	local v="$1"
	local js_jira="$2"
	local rjs=
	local which=
	local i=0
	local cnt=
	local tid=

	case "$v" in
	new|scheduled)
		which="1"
		;;
	active)
		which="3"
		;;
	review)
		which="10300"
		;;
	merged)
		which="5"
		;;
	esac

	rjs=$(FunJira._api "GET" "issue/$FUNJIRA_ISSUE/transitions")
	CLI.die_ifz "$rjs" "failed to get available transitions"

	Plist.init_with_raw "json" "$rjs"
	cnt=$(Plist.get_count "transitions")
	for (( i = 0; i < $cnt; i++ )); do
		local kp="transitions.$i"
		local td=
		local self=
		local sid=

		self=$(Plist.get_value "$kp.to.self" "string")
		CLI.die_ifz "$self" "failed to get transition descriptor"

		# This is the best indication I could find that the transition refers to
		# a status. It might be the case that transitions only ever refer to
		# issue status, but I didn't see any documentation to that effect. So
		# check to make sure here.
		if [[ ! "$self" =~ 'rest/api/2/status/' ]]; then
			continue
		fi

		sid=$(Plist.get_value "$kp.to.id" "string")
		CLI.die_ifz "$sid" "failed to get status id"

		if [ "$sid" == "$which" ]; then
			tid=$(Plist.get_value "$kp.id" "string")
			CLI.die_ifz "$tid" "failed to get transition id"
			break
		fi
	done

	if [ -n "$tid" ]; then
		Plist.init_with_raw "json" "$js_jira"
		Plist.set_value "transition.id" "integer" "$tid"
		Plist.get "json"
	fi
}

function FunJira._from_jira_status()
{
	local js_jira="$1"
	local js="$2"
	local v=

	Plist.init_with_raw "json" "$js_jira"
	v=$(Plist.get_value "fields.status.id" "string")
	CLI.die_ifz "$v" "failed to get status code from json response: $js_jira"

	# A lot of these are redundant because they're used by different teams to
	# express the same thing. But just map all of them for the sake of
	# completeness. There is no specific state for "needs to be scheduled", so
	# we don't interpret anything as "new". But the first case in the mapping
	# below is probably the closest to that, so we break it out.
	case "$v" in
	1|4|10505|10507)
		# Maps to "scheduled", but not quite the best fit for that.
		#
		#     1     -> Open
		#     4     -> Reopened
		#     10505 -> Declined
		#     10507 -> Planning
		echo "scheduled"
		;;
	10000|10200|10401|10501|10510|10511|10512)
		# Maps to "scheduled"
		#
		#     10000 -> To Do
		#     10200 -> Blocked
		#     10401 -> In Design
		#     10501 -> Awaiting Implementation
		#     10510 -> Waiting for Support
		#     10511 -> Waiting for Customer
		#     10512 -> Pending
		echo "scheduled"
		;;
	3|10506)
		# Maps to "active"
		#
		#     3     -> In Progress
		#     10506 -> Implementing
		echo "active"
		;;
	10001|10002|10100|10300|10301|10500)
		# Maps to "review"
		#
		#     10001 -> In Review
		#     10002 -> Done
		#     10100 -> In Unit Test
		#     10300 -> In PR
		#     10301 -> In Bundle Build
		#     10500 -> Awaiting Approval
		echo "review"
		;;
	5|6|10400|10504)
		# Maps to "merged"
		#
		#     5     -> Resolved
		#     6     -> Closed
		#     10400 -> In Prod
		#     10504 -> Complete
		echo "merged"
		;;

	esac

	Plist.init_with_raw "json" "$js"
	Plist.set_value "Status" "string" "$v"
	Plist.get "json"
}

function FunJira._to_jira_branch()
{
	local v="$1"
	local js_jira="$2"
	local js=

	# I'd love to have used plutil(1) for this, but it doesn't output JSON
	# without the root object being a container type, so we cannot use it for
	# general JSON transcoding. Fortunately, we can use json_xs to at least
	# support string encoding. But for some reason, it puts the string "\n" at
	# the end of the encoded property (not a new line, the actual string), so we
	# strip that.
	js=$(json_xs -f string -t json <<< "$v")
	js=$(sed -E 's/\\n\"/"/;' <<< "$js")

	echo "$js"
}

function FunJira._from_jira_branch()
{
	local js_jira="$1"
	local js="$2"
	local v=

	Plist.init_with_raw "json" "$js_jira"
	v=$(Plist.get_value "value" "string")
	CLI.die_ifz "$v" "failed to get property from json response: $js_jira"

	Plist.init_with_raw "json" "$js"
	Plist.set_value "Branch" "string" "$v"
	Plist.get "json"
}

function FunJira._translate_field()
{
	local f="$1"
	local whichway="$2"
	local fieldvec=()

	case "$f" in
	Title)
		fieldvec=(
			"field"
			"Title"
			"FunJira._${whichway}_title"
		)
		;;
	State)
		fieldvec=(
			"transition"
			"State"
			"FunJira._${whichway}_status"
		)
		;;
	Branch)
		fieldvec=(
			"property"
			"Branch"
			"FunJira._${whichway}_branch"
			"fungible.branch"
		)
		;;
	esac

	echo "${fieldvec[*]}"
}

# MARK: Public
function FunJira.init()
{
	local p="$1"
	local n="$2"
	local username="$3"

	# We rely on the CLI and Plist modules, but we're loaded lazily, so we need
	# the importer to load them on our behalf. If we tried to load them
	# directly, we'd overwrite the importer's state from those modules.
	check_available CLI.init
	if [ $? -ne 0 ]; then
		echo "importer must also import CLI"
		exit 1
	fi

	check_available Plist.init_with_file
	if [ $? -ne 0 ]; then
		echo "importer must also import Plist"
		exit 1
	fi

	check_available Git.init
	if [ $? -ne 0 ]; then
		echo "importer must also import Git"
		exit 1
	fi

	check_available Keychain.init
	if [ $? -ne 0 ]; then
		echo "importer must also import Keychain"
		exit 1
	fi

	FUNJIRA_PROJECT="$p"
	FUNJIRA_NUMBER="$n"
	FUNJIRA_USERNAME="$username"

	Module.config 0 "fungible jira"
	Module.config 1 "api" "$FUNJIRA_API"
	Module.config 1 "project" "$FUNJIRA_PROJECT"
	Module.config 1 "number" "$FUNJIRA_NUMBER"
	Module.config 1 "username" "$FUNJIRA_USERNAME"
}

function FunJira.init_tracker()
{
	local js=
	local cnt=
	local pk=

	pk=$(Git.run config "${FUNJIRA_CONFIG}.key")
	if [ -n "$pk" ]; then
		FUNJIRA_KEY="$pk"
		FUNJIRA_ISSUE="${pk}-$FUNJIRA_NUMBER"

		Module.config 1 "issue key" "$FUNJIRA_KEY"
		Module.config 1 "issue" "$FUNJIRA_KEY"
		return 0
	fi

	js=$(FunJira._api "GET" "issue/createmeta")
	CLI.die_ifz "$js" "failed to get project metadata"

	Plist.init_with_raw "json" "$js"
	cnt=$(Plist.get_count "projects")
	CLI.die_ifz "$cnt" "failed to get projects array count"

	for (( i = 0; i < $cnt; i++ )); do
		local k="projects.$i"
		local pd=
		local n=

		pd=$(Plist.get_value_xml "$k" "dictionary")
		if [ -z "$pd" ]; then
			continue
		fi

		Plist.init_with_raw "xml1" "$pd"
		n=$(Plist.get_value "name" "string")
		if [ "$n" = "$FUNJIRA_PROJECT" ]; then
			pk=$(Plist.get_value "key" "string")
			break
		fi

		Plist.init_with_raw "json" "$js"
	done

	CLI.die_ifz "$pk" "failed to get issue key for $FUNJIRA_PROJECT"

	FUNJIRA_KEY="$pk"
	FUNJIRA_ISSUE="${pk}-$FUNJIRA_NUMBER"

	Module.config 1 "issue key" "$FUNJIRA_KEY"
	Module.config 1 "issue" "$FUNJIRA_ISSUE"

	Git.run config --local "${FUNJIRA_CONFIG}.key" "$FUNJIRA_KEY"
	CLI.die_check $? "failed to set issue key in git config"
}

function FunJira.get_tracker_field()
{
	local f="$1"

	case "$f" in
	Key)
		echo "$FUNJIRA_KEY"
		;;
	BugPrefix)
		echo "${FUNJIRA_KEY}-"
		;;
	esac
}

function FunJira.update_field()
{
	local f="$1"
	local v="$2"
	local t="$3"
	local fieldvec=()

	fieldvec=($(FunJira._translate_field "$f" "to_jira"))
	case "${fieldvec[0]}" in
	field)
		FUNJIRA_UPDATE_FIELDS+=(${fieldvec[@]:1:2} "$v")
		;;
	property)
		FUNJIRA_UPDATE_PROPERTIES+=(${fieldvec[@]:1:3} "$v")
		;;
	transition)
		# Jira's transition request body only allows for one transition.
		if [ ${#FUNJIRA_UPDATE_TRANSITIONS[@]} -gt 0 ]; then
			CLI.die "multiple transitions are not supported"
		fi

		FUNJIRA_UPDATE_TRANSITIONS+=(${fieldvec[@]:1:2} "$v")
		;;
	*)
		CLI.die "no translation for field: $f"
	esac
}

function FunJira.query_field()
{
	local f="$1"
	local fieldvec=()

	fieldvec=($(FunJira._translate_field "$f" "from_jira"))
	case "${fieldvec[0]}" in
	field|transition)
		# Transitions operate on fields, so if the Jira field is a transition,
		# we treat it as a field when doing a query.
		FUNJIRA_QUERY_FIELDS+=(${fieldvec[@]:1:2})
		;;
	property)
		FUNJIRA_QUERY_PROPERTIES+=(${fieldvec[@]:1:3})
		;;
	*)
		CLI.die "no translation for field: $f"
	esac
}

function FunJira.update()
{
	local js=

	Plist.init_with_raw "json" '{
		"fields": {

		}
	}'

	js=$(Plist.get "json")
	for (( i = 0; i < "${#FUNJIRA_UPDATE_FIELDS[@]}"; i += 3 )); do
		local f="${FUNJIRA_UPDATE_FIELDS[$(( $i + 0 ))]}"
		local xf="${FUNJIRA_UPDATE_FIELDS[$(( $i + 1 ))]}"
		local v="${FUNJIRA_UPDATE_FIELDS[$(( $i + 2 ))]}"

		js=$($xf "$v" "$js")
		CLI.die_ifz "$js" "failed to update field: $f => $v"

		Plist.init_with_raw "json" "$js"
		js=$(Plist.get "json")
	done

	if [ ${#FUNJIRA_UPDATE_FIELDS[@]} -gt 0 ]; then
		FunJira._api "PUT" "issue/$FUNJIRA_ISSUE" "$js"
		CLI.die_check $? "failed to update issue: $FUNJIRA_ISSUE"
	fi

	js=
	for (( i = 0; i < "${#FUNJIRA_UPDATE_PROPERTIES[@]}"; i += 4 )); do
		local f="${FUNJIRA_UPDATE_PROPERTIES[$(( $i + 0 ))]}"
		local xf="${FUNJIRA_UPDATE_PROPERTIES[$(( $i + 1 ))]}"		
		local p="${FUNJIRA_UPDATE_PROPERTIES[$(( $i + 2 ))]}"
		local v="${FUNJIRA_UPDATE_PROPERTIES[$(( $i + 3 ))]}"

		# Property values are just JSON blobs, so we don't pass anything for the
		# second parameter to the translation function. It just gives back the
		# JSON encoding of the value.
		js=$($xf "$v")
		CLI.die_ifz "$js" "failed to set update property: $f => $v"

		FunJira._api "PUT" "issue/$FUNJIRA_ISSUE/properties/$p" "$js"
		CLI.die_check $? "failed to set property: $p"
	done

	Plist.init_with_raw "json" '{
		"transition": {

		}
	}'

	# Do the transitions last, since our other updates might influence whether
	# they are legal.
	js=$(Plist.get "json")
	for (( i = 0; i < "${#FUNJIRA_UPDATE_TRANSITIONS[@]}"; i += 4 )); do
		local f="${FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 0 ))]}"
		local xf="${FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 1 ))]}"
		local v="${FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 2 ))]}"

		js=$($xf "$v" "$js")
		CLI.die_ifz "$js" "failed to set transition: $f => $v"

		Plist.init_with_raw "json" "$js"
	done

	if [ ${#FUNJIRA_UPDATE_TRANSITIONS[@]} -gt 0 ]; then
		js=$(Plist.get "json")
		FunJira._api "POST" "issue/$FUNJIRA_ISSUE/transitions" "$js"
		CLI.die_check $? "failed to transition issue: $FUNJIRA_ISSUE"
	fi
}

function FunJira.query()
{
	local i=
	local js=
	local jsr='{}'

	for (( i = 0; i < "${#FUNJIRA_QUERY_FIELDS[@]}"; i += 2 )); do
		local f="${FUNJIRA_QUERY_FIELDS[$(( $i + 0 ))]}"
		local xf="${FUNJIRA_QUERY_FIELDS[$(( $i + 1 ))]}"
		local v=

		if [ -z "$js" ]; then
			js=$(FunJira._api "GET" "issue/$FUNJIRA_ISSUE")
			CLI.die_ifz "$js" "failed to query issue: $FUNJIRA_ISSUE"
		fi

		jsr=$($xf "$js" "$jsr")
		CLI.die_ifz "$jsr" "failed to query field: $f"
	done

	# The Jira API only lets us query for one property at a time.
	for (( i = 0; i < "${#FUNJIRA_QUERY_PROPERTIES[@]}"; i += 3 )); do
		local f="${FUNJIRA_QUERY_PROPERTIES[$(( $i + 0 ))]}"
		local xf="${FUNJIRA_QUERY_PROPERTIES[$(( $i + 1 ))]}"		
		local p="${FUNJIRA_QUERY_PROPERTIES[$(( $i + 2 ))]}"

		js=$(FunJira._api "GET" "issue/$FUNJIRA_ISSUE/properties/$p")
		CLI.die_ifz "$js" "failed to query property: $p"

		jsr=$($xf "$js" "$jsr")
		CLI.die_ifz "$jsr" "failed to translate response: $js"
	done

	Plist.init_with_raw "json" "$jsr"
	Plist.get "json"
}
