.PHONY: test shellcheck

test:
	sh tests/run.sh

shellcheck:
	shellcheck -s sh -e SC1091,SC2016,SC2018,SC2019,SC2034,SC2129 $$(find package scripts tests -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/usr/libexec/*' -o -path '*/init.d/*' -o -path '*/hotplug.d/*' -o -path '*/uci-defaults/*' \))
