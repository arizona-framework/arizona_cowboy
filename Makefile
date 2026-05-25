MAKEFLAGS += -j$(shell nproc)

# Force bash so recipes using `set -o pipefail` (check-hank, check-doc) work
# on systems where /bin/sh is dash (Debian/Ubuntu CI runners).
SHELL := /bin/bash

.PHONY: all ci precommit compile compile-test \
	fmt \
	check check-dirty check-fast check-erl check-fmt check-lint check-hank check-xref check-dialyzer \
	test test-eunit test-ct test-erl \
	cover cover-erl \
	doc doc-erl \
	clean

all: ci

ci:
	$(MAKE) compile
	$(MAKE) check-dirty
	$(MAKE) check-erl
	$(MAKE) test-erl
	$(MAKE) cover-erl
	$(MAKE) doc-erl

check-dirty:
	@git diff --quiet || (echo "Error: uncommitted changes after build (run make precommit and commit artifacts)" && git diff --name-only && exit 1)

precommit:
	$(MAKE) fmt
	$(MAKE) compile
	$(MAKE) check-fmt
	$(MAKE) test-erl

compile: compile-test
	rebar3 compile

compile-test:
	rebar3 as test compile

fmt:
	rebar3 fmt

check: check-erl

check-fast: check-fmt

check-erl:
	$(MAKE) check-fmt
	$(MAKE) check-lint
	$(MAKE) check-hank
	$(MAKE) check-xref
	$(MAKE) check-dialyzer

check-fmt:
	rebar3 fmt --check

check-lint:
	rebar3 lint

check-hank:
	@set -o pipefail; rebar3 hank 2>&1 | tee /dev/stderr | \
		(! grep -q "no longer needed")

check-xref:
	rebar3 xref

check-dialyzer:
	rebar3 as test dialyzer

test: test-erl

test-eunit:
	rebar3 as test eunit

test-ct:
	rebar3 as test ct

test-erl:
	rebar3 as test test

cover: cover-erl

cover-erl:
	rebar3 as test check_cover

doc: doc-erl

doc-erl:
	@set -o pipefail; rebar3 doc 2>&1 | tee /dev/stderr | \
		(! grep -q "warning")

clean:
	rebar3 clean
	rm -rf _build
