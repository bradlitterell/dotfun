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
# Note that we can only safely import modules that don't have any state. See the
# comment in FunJira.init.
. "${libdir}/Lib.sh"
. "${libdir}/Module.sh"

# We rely on the CLI and Plist modules, but we're loaded lazily, so we need
# the importer to load them on our behalf. If we tried to load them
# directly, we'd overwrite the importer's state from those modules.
assert_available CLI
assert_available Plist
assert_available Git
assert_available Keychain

# MARK: Globals
G_FUNJIRA_URL="http://jira.fungible.local"
G_FUNJIRA_API="$G_FUNJIRA_URL:8080/rest/api/2"
G_FUNJIRA_CONFIG="bug.FunJira"

# MARK: Object Fields
F_FUNJIRA_PROJECT=
F_FUNJIRA_USERNAME=
F_FUNJIRA_SECRETS=
F_FUNJIRA_KEY=
F_FUNJIRA_ISSUE=
F_FUNJIRA_TIMEOUT=5
F_FUNJIRA_UPDATE_FIELDS=()
F_FUNJIRA_UPDATE_PROPERTIES=()
F_FUNJIRA_UPDATE_TRANSITIONS=()
F_FUNJIRA_QUERY_FIELDS=()
F_FUNJIRA_QUERY_PROPERTIES=()

# MARK: Internal
function FunJira._get_password()
{
	# Fungible's Jira doesn't appear to support personal access tokens, so we
	# have to stash the password in the Keychain and use basic auth.
	Keychain.init_account "$G_FUNJIRA_URL" "$F_FUNJIRA_USERNAME"
	Keychain.get_password_or_prompt
}

function FunJira._api()
{
	local which="$1"
	local call="$2"
	local data="$3"
	local url="$G_FUNJIRA_API/$call"
	local auth=
	local pw=
	local r=
	local http_status=
	local message=

	pw=$(FunJira._get_password)
	CLI.die_ifz $? "failed to get jira password for $F_FUNJIRA_USERNAME"

	# The Jira server is a bit flaky, so we just always use a timeout.
	auth="${F_FUNJIRA_USERNAME}:$pw"
	if [ -n "$data" ]; then
		CLI.debug "sending request: $which: $url: $data"
		r=$(CLI.run v curl -s -X "$which" \
				-H 'Accept: application/json' \
				-H "Content-Type: application/json" \
				-m "$F_FUNJIRA_TIMEOUT" \
				-d "$data" \
				-K- \
				"$url" <<< "--user $auth")
	else
		CLI.debug "sending request: $which: $url"
		r=$(CLI.run v curl -s -X "$which" \
				-H 'Accept: application/json' \
				-H "Content-Type: application/json" \
				-m "$F_FUNJIRA_TIMEOUT" \
				-K- \
				"$url" <<< "--user $auth")
	fi

	CLI.debug "got response: $r"
	Plist.init_with_raw "json" "$r"
	http_status=$(Plist.get_value "status-code" "integer" "200")
	case "$http_status" in
	20[0-9])
		message=$(Plist.get_value "errorMessages.0" "string")
		if [ -n "$message" ]; then
			# Jira uses http status codes except when it doesn't.
			CLI.die "api call failed with response: $message: $r"
		fi

		echo "$r"
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

	rjs=$(FunJira._api "GET" "issue/$F_FUNJIRA_ISSUE/transitions")
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
	CLI.die_ifz "$v" "failed to get status id from json response: $js_jira"

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
		v="scheduled"
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
		v="scheduled"
		;;
	3|10506)
		# Maps to "active"
		#
		#     3     -> In Progress
		#     10506 -> Implementing
		v="active"
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
		v="review"
		;;
	5|6|10400|10504)
		# Maps to "merged"
		#
		#     5     -> Resolved
		#     6     -> Closed
		#     10400 -> In Prod
		#     10504 -> Complete
		v="merged"
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

function FunJira._to_jira_component()
{
	local v="$1"
	local js_jira="$2"
	local js='{
		"update": {
			"components": [
				{
					"set": [
						{

						}
					]
				}
			]
		}
	}'

	# I'm a bit surprised that setting the component isn't a transition, since
	# you might want to enforce access controls on issues that were in one
	# component before transitioning them to another component that is e.g. less
	# restricted.
	Plist.init_with_raw "json" "$js"
	Plist.set_value "update.components.0.set.0.name" "$v"
	Plist.get "json"
}

function FunJira._from_jira_component()
{
	local js_jira="$1"
	local js="$2"
	local v=

	# Jira allows for an issue to refer to multiple components, but mercifully,
	# I don't think we need that.
	Plist.init_with_raw "json" "$js_jira"
	v=$(Plist.get_value "fields.components.0.name" "string")
	CLI.die_ifz "$v" "failed to get component from json response: $js_jira"

	Plist.init_with_raw "json" "$js"
	Plist.set_value "Component" "string" "$v"
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
	Component)
		fieldvec=(
			"field"
			"Component"
			"FunJira._${whichway}_component"
		)
		;;
	esac

	echo "${fieldvec[*]}"
}

# MARK: Public
function FunJira.init()
{
	local p="$1"
	local username="$2"
	local secrets="$3"

	F_FUNJIRA_PROJECT="$p"
	F_FUNJIRA_USERNAME="$username"
	F_FUNJIRA_SECRETS="$secrets"

	CLI.print_field 0 "fungible jira"
	CLI.print_field 1 "api" "$G_FUNJIRA_API"
	CLI.print_field 1 "project" "$F_FUNJIRA_PROJECT"
	CLI.print_field 1 "username" "$F_FUNJIRA_USERNAME"
	CLI.print_field 1 "secrets store" "$F_FUNJIRA_SECRETS"
}

function FunJira.init_problem()
{
	local n="$1"

	F_FUNJIRA_ISSUE="$n"
	CLI.print_field 0 "fungible jira issue"
	CLI.print_field 1 "identifier" "$F_FUNJIRA_ISSUE"
}

function FunJira.set_request_timeout()
{
	local to="$1"
	F_FUNJIRA_TIMEOUT=$to
}

function FunJira.query_tracker_property()
{
	local f="$1"
	local sep=

	if [[ "$f" =~ ^BugPrefix ]]; then
		sep="-"
	fi

	case "$f" in
	Key|BugPrefix)
		local js=
		local cnt=
		local pk=

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
			if [ "$n" = "$F_FUNJIRA_PROJECT" ]; then
				pk=$(Plist.get_value "key" "string")
				break
			fi

			Plist.init_with_raw "json" "$js"
		done

		CLI.die_ifz "$pk" "failed to get issue key for $F_FUNJIRA_PROJECT"

		# Now that we have the key, cache it.
		Git.run config --local "${G_FUNJIRA_CONFIG}.key" "$pk"
		if [ $? -ne 0 ]; then
			CLI.warn "failed to cache issue key: $pk"
		fi

		if [ -n "$pk" ]; then
			echo "${pk}${sep}"
		fi
		;;
	Key$|BugPrefix$)
		pk=$(Git.run config "${G_FUNJIRA_CONFIG}.key")
		if [ -n "$pk" ]; then
			echo "${pk}${sep}"
		fi
		;;
	esac
}

function FunJira.add_comment()
{
	local c="$1"
	local js='{}'

	Plist.init_with_raw "json" "$js"
	Plist.set_value "body" "string" "$c"
	js=$(Plist.get "json")

	q FunJira._api "POST" "issue/$F_FUNJIRA_ISSUE/comment" "$js"
	CLI.warn_check $? "add comment to issue"
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
		F_FUNJIRA_UPDATE_FIELDS+=(${fieldvec[@]:1:2} "$v")
		;;
	property)
		F_FUNJIRA_UPDATE_PROPERTIES+=(${fieldvec[@]:1:3} "$v")
		;;
	transition)
		# Jira's transition request body only allows for one transition.
		if [ ${#F_FUNJIRA_UPDATE_TRANSITIONS[@]} -gt 0 ]; then
			CLI.die "multiple transitions are not supported"
		fi

		F_FUNJIRA_UPDATE_TRANSITIONS+=(${fieldvec[@]:1:2} "$v")
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
		F_FUNJIRA_QUERY_FIELDS+=(${fieldvec[@]:1:2})
		;;
	property)
		F_FUNJIRA_QUERY_PROPERTIES+=(${fieldvec[@]:1:3})
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
	for (( i = 0; i < "${#F_FUNJIRA_UPDATE_FIELDS[@]}"; i += 3 )); do
		local f="${F_FUNJIRA_UPDATE_FIELDS[$(( $i + 0 ))]}"
		local xf="${F_FUNJIRA_UPDATE_FIELDS[$(( $i + 1 ))]}"
		local v="${F_FUNJIRA_UPDATE_FIELDS[$(( $i + 2 ))]}"

		js=$($xf "$v" "$js")
		CLI.die_ifz "$js" "failed to update field: $f => $v"

		Plist.init_with_raw "json" "$js"
		js=$(Plist.get "json")
	done

	if [ ${#F_FUNJIRA_UPDATE_FIELDS[@]} -gt 0 ]; then
		FunJira._api "PUT" "issue/$F_FUNJIRA_ISSUE" "$js"
		CLI.die_check $? "failed to update issue: $F_FUNJIRA_ISSUE"
	fi

	js=
	for (( i = 0; i < "${#F_FUNJIRA_UPDATE_PROPERTIES[@]}"; i += 4 )); do
		local f="${F_FUNJIRA_UPDATE_PROPERTIES[$(( $i + 0 ))]}"
		local xf="${F_FUNJIRA_UPDATE_PROPERTIES[$(( $i + 1 ))]}"
		local p="${F_FUNJIRA_UPDATE_PROPERTIES[$(( $i + 2 ))]}"
		local v="${F_FUNJIRA_UPDATE_PROPERTIES[$(( $i + 3 ))]}"

		# Property values are just JSON blobs, so we don't pass anything for the
		# second parameter to the translation function. It just gives back the
		# JSON encoding of the value.
		js=$($xf "$v")
		CLI.die_ifz "$js" "failed to set update property: $f => $v"

		q FunJira._api "PUT" "issue/$F_FUNJIRA_ISSUE/properties/$p" "$js"
		CLI.die_check $? "failed to set property: $p"
	done

	Plist.init_with_raw "json" '{
		"transition": {

		}
	}'

	# Do the transitions last, since our other updates might influence whether
	# they are legal.
	js=$(Plist.get "json")
	for (( i = 0; i < "${#F_FUNJIRA_UPDATE_TRANSITIONS[@]}"; i += 4 )); do
		local f="${F_FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 0 ))]}"
		local xf="${F_FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 1 ))]}"
		local v="${F_FUNJIRA_UPDATE_TRANSITIONS[$(( $i + 2 ))]}"

		js=$($xf "$v" "$js")
		CLI.die_ifz "$js" "failed to set transition: $f => $v"

		Plist.init_with_raw "json" "$js"
	done

	if [ ${#F_FUNJIRA_UPDATE_TRANSITIONS[@]} -gt 0 ]; then
		js=$(Plist.get "json")
		q FunJira._api "POST" "issue/$F_FUNJIRA_ISSUE/transitions" "$js"
		CLI.warn_check $? "transition issue: $F_FUNJIRA_ISSUE"
	fi
}

function FunJira.query()
{
	local i=
	local js=
	local jsr='{}'

	for (( i = 0; i < "${#F_FUNJIRA_QUERY_FIELDS[@]}"; i += 2 )); do
		local f="${F_FUNJIRA_QUERY_FIELDS[$(( $i + 0 ))]}"
		local xf="${F_FUNJIRA_QUERY_FIELDS[$(( $i + 1 ))]}"
		local v=

		if [ -z "$js" ]; then
			js=$(FunJira._api "GET" "issue/$F_FUNJIRA_ISSUE")
			CLI.die_ifz "$js" "failed to query issue: $F_FUNJIRA_ISSUE"
		fi

		jsr=$($xf "$js" "$jsr")
		CLI.die_ifz "$jsr" "failed to query field: $f"
	done

	# The Jira API only lets us query for one property at a time.
	for (( i = 0; i < "${#F_FUNJIRA_QUERY_PROPERTIES[@]}"; i += 3 )); do
		local f="${F_FUNJIRA_QUERY_PROPERTIES[$(( $i + 0 ))]}"
		local xf="${F_FUNJIRA_QUERY_PROPERTIES[$(( $i + 1 ))]}"
		local p="${F_FUNJIRA_QUERY_PROPERTIES[$(( $i + 2 ))]}"

		js=$(FunJira._api "GET" "issue/$F_FUNJIRA_ISSUE/properties/$p")
		CLI.die_ifz "$js" "failed to query property: $p"

		jsr=$($xf "$js" "$jsr")
		CLI.die_ifz "$jsr" "failed to translate response: $js"
	done

	Plist.init_with_raw "json" "$jsr"
	Plist.get "json"
}
