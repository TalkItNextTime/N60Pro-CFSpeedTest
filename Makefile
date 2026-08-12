.PHONY: test shellcheck

test:
	sh tests/run.sh

shellcheck:
	shellcheck -s sh $$(find package scripts tests -type f \( -name '*.sh' -o -path '*/usr/bin/*' -o -path '*/usr/libexec/*' \))
