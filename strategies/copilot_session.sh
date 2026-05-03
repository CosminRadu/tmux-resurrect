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
# If no matching session is found on disk, the original command is
# echoed unchanged - copilot relaunches fresh, same as without this
# strategy.

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

main() {
	local target_dir target_resolved uuid filtered
	local -a tokens

	if [ -z "$DIRECTORY" ]; then
		echo "$ORIGINAL_COMMAND"
		return 0
	fi

	target_dir="$DIRECTORY"
	target_resolved="$(resolved_dir)"
	uuid="$(find_session_uuid "$target_dir" "$target_resolved")"

	if [ -z "$uuid" ]; then
		echo "$ORIGINAL_COMMAND"
		return 0
	fi

	# Word-split the saved command. Copilot argv values do not normally
	# contain shell metacharacters; if they do, this is the same level
	# of fidelity tmux-resurrect already provides for restored commands.
	read -ra tokens <<< "$ORIGINAL_COMMAND"
	filtered="$(filter_argv "${tokens[@]}")"

	if [ -n "$filtered" ]; then
		echo "${filtered} --resume=${uuid}"
	else
		echo "copilot --resume=${uuid}"
	fi
}
main
