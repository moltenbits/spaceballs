.PHONY: build release clean test run run.json everything format lint install bootstrap kill

# Build configuration
SWIFT_BUILD_FLAGS = --disable-sandbox
RELEASE_FLAGS = -c release $(SWIFT_BUILD_FLAGS)
DEBUG_FLAGS = -c debug $(SWIFT_BUILD_FLAGS)
PREFIX ?= /usr/local
APP_BUNDLE = .build/Spacebar.app

# Usage: $(call bundle_app,source_binary,info_plist,target_bundle,sign_identity)
define bundle_app
	@mkdir -p $(3)/Contents/MacOS
	@cp $(1) $(3)/Contents/MacOS/spacebar
	@cp $(2) $(3)/Contents/Info.plist
	@codesign --force --sign $(4) $(3)
endef

help: ## This help screen
	@IFS=$$'\n' ; \
	help_lines=(`fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##/:/'`); \
	printf "%-30s %s\n" "Target" "Function" ; \
	printf "%-30s %s\n" "------" "----" ; \
	for help_line in $${help_lines[@]}; do \
		IFS=$$':' ; \
		help_split=($$help_line) ; \
		help_command=`echo $${help_split[0]} | sed -e 's/^ *//' -e 's/ *$$//'` ; \
		help_info=`echo $${help_split[2]} | sed -e 's/^ *//' -e 's/ *$$//'` ; \
		printf '\033[36m'; \
		printf "%-30s %s" $$help_command ; \
		printf '\033[0m'; \
		printf "%s\n" $$help_info; \
	done

bootstrap: ## Install required tooling
bootstrap: brewfile

brewfile:
	@brew bundle install

build: ## Debug build (GUI + CLI) + bundle .app
	swift build $(DEBUG_FLAGS) --product spacebar-gui
	swift build $(DEBUG_FLAGS) --product spacebar
	$(call bundle_app,.build/debug/spacebar-gui,Resources/Info.plist,$(APP_BUNDLE),"Spacebar Dev")

release: ## Release build (GUI + CLI) + bundle .app
	swift build $(RELEASE_FLAGS) --product spacebar-gui
	swift build $(RELEASE_FLAGS) --product spacebar
	$(call bundle_app,.build/release/spacebar-gui,Resources/Info.plist,$(APP_BUNDLE),"Spacebar Dev")

everything: ## Kill + release build + install CLI + open the .app
everything: kill install
	@open -n $(APP_BUNDLE)

run: ## Build + run CLI (text output)
	swift build $(DEBUG_FLAGS) --product spacebar
	swift run $(SWIFT_BUILD_FLAGS) spacebar

run.json: ## Build + run CLI (JSON output)
	swift build $(DEBUG_FLAGS) --product spacebar
	swift run $(SWIFT_BUILD_FLAGS) spacebar --json

kill: ## Kill running Spacebar app
	@pkill -f "Spacebar.app" 2>/dev/null || true

clean: ## Remove .build/
	swift package clean
	rm -rf .build dist

test: ## Run tests
	swift test $(SWIFT_BUILD_FLAGS)

format: ## Format code
	swift-format -i -r Sources/ Tests/

lint: ## Lint code
	swift-format lint -r Sources/ Tests/

install: ## Release build + install CLI binary + CLI .app bundle
install: release
	@echo "Installing spacebar to $(PREFIX)/bin..."
	@mkdir -p $(PREFIX)/bin
	@if [ -w $(PREFIX)/bin ]; then \
		cp .build/release/spacebar $(PREFIX)/bin/spacebar; \
	else \
		sudo cp .build/release/spacebar $(PREFIX)/bin/spacebar; \
	fi
	@echo "Installing Spacebar-CLI.app to $(PREFIX)/lib/spacebar/..."
	@if [ -w $(PREFIX) ]; then \
		mkdir -p $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/MacOS; \
		cp .build/release/spacebar $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/MacOS/spacebar; \
		cp Resources/Info-CLI.plist $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/Info.plist; \
		codesign --force --sign - $(PREFIX)/lib/spacebar/Spacebar-CLI.app; \
	else \
		sudo mkdir -p $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/MacOS; \
		sudo cp .build/release/spacebar $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/MacOS/spacebar; \
		sudo cp Resources/Info-CLI.plist $(PREFIX)/lib/spacebar/Spacebar-CLI.app/Contents/Info.plist; \
		sudo codesign --force --sign - $(PREFIX)/lib/spacebar/Spacebar-CLI.app; \
	fi
	@echo "Installed! Run 'spacebar --help' to get started."
