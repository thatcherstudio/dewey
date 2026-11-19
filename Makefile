# make app       build build/Dewey.app, with its own Python and dewey (needs Xcode 16+ or the
#                Swift 6 command-line tools, and uv)
# make run       build it and open it
# make test      Python tests, then Swift tests (with ~/.venvs/dewey)
# make test-app  the same tests against the Python and dewey inside build/Dewey.app
PYTHON ?= $(HOME)/.venvs/dewey/bin/python

.PHONY: app debug run test test-python test-mac test-app clean

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

clean:
	rm -rf build mac/.build
