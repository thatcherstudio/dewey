# make app       build build/Dewey.app, with its own Python and dewey (needs Xcode 16+ or the
#                Swift 6 command-line tools, and uv)
# make run       build it and open it
# make test      Python tests, then Swift tests (with ~/.venvs/dewey)
# make test-app  the same tests against the Python and dewey inside build/Dewey.app
# make pins      move constraints.txt (the exact packages the app bundles) to today's newest versions
PYTHON ?= $(HOME)/.venvs/dewey/bin/python

.PHONY: app debug run test test-python test-mac test-app pins clean

app:
	scripts/build-app.sh release

debug:
	scripts/build-app.sh debug

run: app
	open build/Dewey.app

test: test-python test-mac

test-python:
	$(PYTHON) -m unittest discover -s tests

test-mac:
	swift test --package-path mac

BUNDLED = $(CURDIR)/build/Dewey.app/Contents/Resources
test-app: app
	$(BUNDLED)/python/bin/python3 -I -B -m unittest discover -s tests
	DEWEY_TEST_DEWEY=$(BUNDLED)/bin/dewey swift test --package-path mac

# Every package dewey's extras need, at one exact version, with the checksums of its files. The app
# is built from these and CI tests with them, so neither changes on the day a package is released.
# After this: make test-app, then commit constraints.txt.
pins:
	uv pip compile pyproject.toml --extra all --universal --python-version 3.11 --generate-hashes \
	    --upgrade --quiet --custom-compile-command "make pins" -o constraints.txt

clean:
	rm -rf build mac/.build
