.PHONY: help install uninstall dev build test bench clean
.DEFAULT_GOAL := help

help:               ## Show this list
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk -F':.*?## ' '{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Detailed help: ./install.sh --help, ./uninstall.sh --help"


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
