.PHONY: install uninstall dev build test bench clean

install:            ## Build, sign, install to /Applications, set up access
	@./install.sh

uninstall:          ## Remove the app, preferences, certificate and access grant
	@./uninstall.sh

dev:                ## Build and run from ./build without installing
	@./install.sh --dev

build:              ## Assemble build/DiskMap.app
	@Scripts/build-app.sh

test:               ## Run the test suite
	@swift test

bench:              ## Capacity report for every mounted volume
	@swift build -c release --product dmbench
	@.build/release/dmbench volume

clean:
	@rm -rf .build build
