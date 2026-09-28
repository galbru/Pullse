APP := build/Pullse.app
INSTALLED := $(HOME)/Applications/Pullse.app

.PHONY: build test run check demo dist stats install uninstall clean

build:
	scripts/build-app.sh

test:
	scripts/test.sh

run: build
	open "$(APP)"

# One live fetch: prints what the last 24h would have notified about, then exits.
check: build
	"$(APP)/Contents/MacOS/Pullse" --check

# Render the README's animated GIFs from made-up sample data. Launched with `open` so
# macOS makes the app active: run straight from a terminal it stays in the background,
# where controls draw inactive (grey switches). open -W waits for it to finish; open
# can't write to a pipe, so the capture's output goes to a log that is printed afterwards.
CAPTURE_LOG := $(CURDIR)/build/capture.log
CAPTURE = rm -f "$(CAPTURE_LOG)"; open -W -n "$(APP)" --stdout "$(CAPTURE_LOG)" --stderr "$(CAPTURE_LOG)" --args

demo: build
	$(CAPTURE) --demo "$(CURDIR)/docs/demo"; cat "$(CAPTURE_LOG)"

# Zip the app with its SHA-256 for download: build/Pullse-<version>.zip(.sha256).
dist: build
	scripts/package.sh

# Read-only download counts per release (manual downloads vs in-app updates), plus traffic.
stats:
	scripts/stats.sh

install: build
	mkdir -p "$(HOME)/Applications"
	-pkill -x Pullse
	rm -rf "$(INSTALLED)"
	cp -R "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

uninstall:
	-pkill -x Pullse
	rm -rf "$(INSTALLED)"

clean:
	rm -rf .build build
