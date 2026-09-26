.PHONY: test shellcheck

test:
	sh tests/run.sh

shellcheck:
	@tmp="$${TMPDIR:-/tmp}/cfst-shellcheck.$$"; status=0; shellcheck -s sh -e SC1091,SC2016,SC2018,SC2019,SC2034,SC2129 $$(find package scripts tests -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/usr/libexec/*' -o -path '*/init.d/*' -o -path '*/hotplug.d/*' -o -path '*/uci-defaults/*' \)) >"$$tmp" 2>&1 || status=$$?; cat "$$tmp"; while IFS= read -r line; do printf '::error title=ShellCheck::%s\n' "$$line"; done <"$$tmp"; rm -f "$$tmp"; exit $$status
