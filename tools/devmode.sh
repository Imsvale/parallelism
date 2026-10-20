#!/bin/sh
# Dev mode on or off for this project's working copy (see devmode/devmode.conf).
#   tools/devmode.sh on | off | auto | status
# auto: on when the branch is dev, off otherwise (the post-checkout hook calls this).
# Files it changes are marked skip-worktree, so git never shows them as changed and they
# are never committed; off restores them from HEAD. To edit one of them for real (a new
# cover, say), run "off" first.
cd "$(git rev-parse --show-toplevel)" || exit 1
conf=devmode/devmode.conf
[ -f "$conf" ] || exit 0
mode=${1:-auto}
if [ "$mode" = auto ]; then
	[ "$(git rev-parse --abbrev-ref HEAD)" = dev ] && mode=on || mode=off
fi
grep -v '^\s*#' "$conf" | while read -r action file source; do
	[ -n "$action" ] || continue
	case "$mode" in
	on)
		if [ "$action" = remove ]; then
			git update-index --skip-worktree -- "$file" && rm -f -- "$file"
		elif [ "$action" = replace ] && [ -f "$source" ]; then
			git update-index --skip-worktree -- "$file" && cp -- "$source" "$file"
		fi
		;;
	off)
		git update-index --no-skip-worktree -- "$file" 2>/dev/null
		git checkout HEAD -- "$file" 2>/dev/null
		;;
	status)
		flag=$(git ls-files -v -- "$file" | cut -c1)
		[ "$flag" = S ] && echo "dev   $file" || echo "plain $file"
		;;
	esac
done
[ "$mode" = status ] || echo "dev mode $mode"
