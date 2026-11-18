# make app   build build/Dewey.app (the Mac app; needs Xcode 16+ or the Swift 6 command-line tools)
# make run   build it and open it
# make test  Python tests, then Swift tests
PYTHON ?= $(HOME)/.venvs/dewey/bin/python

.PHONY: app debug run test test-python test-mac clean

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

clean:
	rm -rf build mac/.build
