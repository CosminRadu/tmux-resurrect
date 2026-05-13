#!/usr/bin/env bash

# "copilot session strategy"
#
# Restores a GitHub Copilot CLI session by matching the saved working
# directory against the `cwd` field recorded in each Copilot session's
# workspace.yaml. The most recently updated matching session wins; its
# UUID is appended to the original argv as `--resume=<UUID>`.
#
# Session-selection flags (--resume*, --continue, --connect*, --name*,
# --acp, -i/--interactive, -p/--prompt) are stripped from the saved
# argv before --resume is appended, since they conflict with explicit
# session resumption. All other flags (--autopilot, --allow-all-tools,
# --add-dir, --model, --agent, MCP options, etc.) are preserved.
#
# Additional flags can be force-injected via the tmux option
# `@resurrect-strategy-copilot-default-flags` - useful for flags like
# --yolo / --allow-all-tools that must be present on every relaunch but
# may have been lost from the saved argv (e.g. because the user once
# manually re-launched copilot without them). Tokens already present in
# the saved argv are not duplicated, so this is idempotent across
# repeated save/restore cycles.
#
# If no matching session is found on disk, the original command is
# echoed unchanged - copilot relaunches fresh, same as without this
# strategy. Default flags are still injected in that case.

ORIGINAL_COMMAND="$1"
DIRECTORY="$2"

STATE_ROOT="${COPILOT_STATE_DIR:-$HOME/.copilot/session-state}"

# Resolve $DIRECTORY through symlinks. workspace.yaml records cwd in
# whatever form Copilot inherited from its parent shell (typically the
# logical $PWD), so we may need to compare against either the as-given
# path or the fully resolved path.
resolved_dir() {
	(cd "$DIRECTORY" 2>/dev/null && pwd -P) || echo "$DIRECTORY"
}

# Read the value for a top-level YAML key (e.g. "cwd:" or "id:") from
# a workspace.yaml file. Trims surrounding whitespace and quotes.
yaml_value() {
	local file="$1" key="$2"
	awk -v k="^${key}:" '
		$0 ~ k {
			sub(k, "")
			sub(/^[ \t]+/, "")
			sub(/[ \t]+$/, "")
			gsub(/^["'\'']|["'\'']$/, "")
			print
			exit
		}
	' "$file"
}

# Cross-platform mtime in seconds since epoch.
file_mtime() {
	local file="$1"
	stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null
}

find_session_uuid() {
	local target_dir="$1" target_resolved="$2"
	local best_uuid="" best_ts=0
	local ws cwd ts uuid
	local files_seen=0 files_with_cwd=0

	[ -d "$STATE_ROOT" ] || return 0

	for ws in "$STATE_ROOT"/*/workspace.yaml; do
		[ -f "$ws" ] || continue
		files_seen=$((files_seen + 1))
		cwd="$(yaml_value "$ws" cwd)"
		[ -n "$cwd" ] && files_with_cwd=$((files_with_cwd + 1))
		[ "$cwd" = "$target_dir" ] || [ "$cwd" = "$target_resolved" ] || continue
		ts="$(file_mtime "$ws")"
		[ -n "$ts" ] || continue
		if [ "$ts" -gt "$best_ts" ]; then
			uuid="$(yaml_value "$ws" id)"
			# Reject anything that isn't a canonical UUID.
			if [[ "$uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
				best_ts="$ts"
				best_uuid="$uuid"
			fi
		fi
	done

	# Schema-change likely: if we scanned files but none had a cwd key,
	# Copilot likely renamed or restructured the field.
	if [ "$files_seen" -gt 0 ] && [ "$files_with_cwd" -eq 0 ]; then
		echo "tmux-resurrect copilot strategy: scanned $files_seen workspace.yaml file(s), none had 'cwd' key. Copilot session schema may have changed." >&2
	fi

	[ -n "$best_uuid" ] && echo "$best_uuid"
}

# Strip session-selection flags from the saved argv. Handles both
# `--flag value` and `--flag=value` forms.
filter_argv() {
	local out=() skip=0 tok
	for tok in "$@"; do
		if [ "$skip" -eq 1 ]; then
			skip=0
			continue
		fi
		case "$tok" in
			--resume|--connect|--name|-p|--prompt) skip=1 ;;        # eat the next arg
			--continue|--acp|-i|--interactive)     ;;               # bare flag, no value
			--resume=*|--continue=*|--connect=*|--name=*|--acp=*) ;;
			-p=*|--prompt=*)                       ;;
			*)                                     out+=("$tok") ;;
		esac
	done
	printf '%s\n' "${out[*]}"
}

# Return the "flag name" portion of a token: '--foo=bar' -> '--foo',
# '--foo' -> '--foo', '-x' -> '-x', positional -> empty.
flag_name() {
	local tok="$1"
	case "$tok" in
		--*=*) echo "${tok%%=*}" ;;
		--*|-?*) echo "$tok" ;;
		*)     echo "" ;;
	esac
}

# Read configured default-flags from tmux. Returns empty when unset or
# when not running under tmux (e.g. invoked from a unit test).
configured_default_flags() {
	command -v tmux >/dev/null 2>&1 || return 0
	tmux show-option -gqv "@resurrect-strategy-copilot-default-flags" 2>/dev/null
}

# Append each token from $default_flags to $argv unless a token with
# the same flag-name is already present. Non-flag tokens are appended
# as-is.
merge_default_flags() {
	local default_flags="$1"
	shift
	local -a argv=("$@")
	local -a defaults
	read -ra defaults <<< "$default_flags"

	local def def_name existing have
	for def in "${defaults[@]}"; do
		def_name="$(flag_name "$def")"
		have=0
		if [ -n "$def_name" ]; then
			for existing in "${argv[@]}"; do
				[ "$(flag_name "$existing")" = "$def_name" ] && { have=1; break; }
			done
		fi
		[ "$have" -eq 0 ] && argv+=("$def")
	done
	printf '%s\n' "${argv[*]}"
}

main() {
	local target_dir target_resolved uuid filtered default_flags
	local -a tokens filtered_tokens

	if [ -z "$DIRECTORY" ]; then
		echo "$ORIGINAL_COMMAND"
		return 0
	fi

	# Word-split the saved command. Copilot argv values do not normally
	# contain shell metacharacters; if they do, this is the same level
	# of fidelity tmux-resurrect already provides for restored commands.
	read -ra tokens <<< "$ORIGINAL_COMMAND"

	target_dir="$DIRECTORY"
	target_resolved="$(resolved_dir)"
	uuid="$(find_session_uuid "$target_dir" "$target_resolved")"

	default_flags="$(configured_default_flags)"

	if [ -z "$uuid" ]; then
		# No matching session - echo original command, but still inject
		# default flags so a fresh copilot relaunch gets e.g. --yolo.
		if [ -n "$default_flags" ] && [ ${#tokens[@]} -gt 0 ]; then
			merge_default_flags "$default_flags" "${tokens[@]}"
		else
			echo "$ORIGINAL_COMMAND"
		fi
		return 0
	fi

	filtered="$(filter_argv "${tokens[@]}")"
	read -ra filtered_tokens <<< "$filtered"
	# Ensure argv has at least the binary name before merging.
	[ ${#filtered_tokens[@]} -eq 0 ] && filtered_tokens=("copilot")

	if [ -n "$default_flags" ]; then
		filtered="$(merge_default_flags "$default_flags" "${filtered_tokens[@]}")"
	fi

	echo "${filtered} --resume=${uuid}"
}
main
