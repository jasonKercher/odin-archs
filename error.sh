#!/bin/bash

##
# error catching/raising/reporting
##

# printf to stderr
eprintf() {
	1>&2 printf "$@"
}

# echo to stderr
eprintln() {
	1>&2 echo "$*"
}

# set variable $?
error_set() {
	return $1
}

# raise error or warning
# --email   sends out warning or error to $g_email
# --no-exit issues a warning and does not exit the script
error_raise() {
	local res=$?
	[ $res -eq 0 ] && res=255

	local shift_count=0
	local no_exit=false
	if [ "$1" = --no-exit ] || [ "$2" = --no-exit ]; then
		no_exit=true
		((++shift_count))
	fi

	local send_email=false
	if [ "$1" = --email ] || [ "$2" = --email ]; then
		send_email=true
		((++shift_count))
	fi
	shift $shift_count

	local msg="$1"

	if declare -F CLEAN_UP >> /dev/null; then
		CLEAN_UP "$@"
	fi

	eprintln "$msg"

	if $send_email && [ -n "$g_email" ]; then
		# TODO: make version that supports html
		if $no_exit; then
			mail -s "Warning: ${msg:0:25}" "$g_email" <<< "$msg"
		else
			mail -s "Error: ${msg:0:25}" "$g_email" <<< "$msg"
		fi
	fi

	$no_exit && return "$res"
	exit $res
}

error_catch() {
	local res=$?
	if [ $res -eq 0 ]; then
		return 0
	fi

	error_set $res
	error_raise "$@"
}
