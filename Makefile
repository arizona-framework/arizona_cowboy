MAKEFLAGS += -j$(shell nproc)

# Force bash so recipes using `set -o pipefail` (check-hank, check-doc) work
# on systems where /bin/sh is dash (Debian/Ubuntu CI runners).
SHELL := /bin/bash

.PHONY: all ci precommit compile compile-test \
	fmt \
	check check-dirty check-fast check-erl check-fmt check-lint check-hank check-xref check-dialyzer \
	test test-eunit test-ct test-erl test-conformance \
	cover cover-erl \
	doc doc-erl \
	clean

all: ci

ci:
	$(MAKE) compile
	$(MAKE) check-dirty
	$(MAKE) check-erl
	$(MAKE) test-erl
	$(MAKE) test-conformance
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
	rebar3 as test xref

check-dialyzer:
	rebar3 as test dialyzer

test: test-erl

test-eunit:
	rebar3 as test eunit

test-ct:
	rebar3 as test ct

test-erl:
	rebar3 as test test

# Arizona's conformance suite, run against this checkout: arizona's test profile
# depends on this package, and a `_checkouts` link swaps in the local tree. The
# smoke suite above only boots a listener; this is what verifies the adapter.
ARIZONA_REPO ?= https://github.com/arizona-framework/arizona.git
ARIZONA_REF ?= main
ARIZONA_DIR ?= $(CURDIR)/../.arizona_cowboy-conformance

test-conformance:
	rm -rf $(ARIZONA_DIR)
	git clone --quiet --depth 1 --branch $(ARIZONA_REF) $(ARIZONA_REPO) $(ARIZONA_DIR)
	mkdir -p $(ARIZONA_DIR)/_checkouts
	ln -s $(CURDIR) $(ARIZONA_DIR)/_checkouts/arizona_cowboy
	cd $(ARIZONA_DIR) && ARIZONA_CONFORMANCE_DRIVER=arizona_conformance_cowboy \
		rebar3 as test ct --suite=arizona_server_conformance_SUITE

# The smoke suite alone covers little of the adapter; arizona's suites exercise
# it, so this is informational, not a gate.
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
