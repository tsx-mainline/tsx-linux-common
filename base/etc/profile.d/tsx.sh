alias ll='ls -la'
export PAGER=less
# login banner: the dynamic line under /etc/motd (interactive shells only)
case $- in *i*)
	[ -r /etc/tsx/build-id ] && printf '   build %s, kernel %s\n\n' "$(cat /etc/tsx/build-id)" "$(uname -r)"
	# Lines of the board for the login banner (the boot status command, for example).
	[ -r /etc/tsx/motd.board ] && { cat /etc/tsx/motd.board; echo; }
	# Root password (see tsx-rootpw): once at each interactive root login, in
	# the words for a person who is logged in already (over SSH, mostly).
	# /etc/motd (tsx-banner) does not repeat it; the screen words are in
	# /etc/issue.
	if [ "$(id -u)" = 0 ] && [ -x /usr/local/bin/tsx-rootpw ]; then
		/usr/local/bin/tsx-rootpw note ssh; echo
	fi;;
esac
