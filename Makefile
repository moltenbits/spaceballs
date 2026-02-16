.PHONY: build release clean test run run.json run.activate app format lint install brewfile build-gui app-gui gui kill

# Build configuration
SWIFT_BUILD_FLAGS = --disable-sandbox
RELEASE_FLAGS = -c release $(SWIFT_BUILD_FLAGS)
DEBUG_FLAGS = -c debug $(SWIFT_BUILD_FLAGS)
PREFIX ?= /usr/local
APP_BUNDLE = .build/Spacebar.app

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

bootstrap: ## Bootstraps the project with all required tooling
bootstrap: brewfile

brewfile: ## Install all required brews for this project
	@brew bundle install

build: ## Build debug executable
	swift build $(DEBUG_FLAGS)

release: ## Build release executable
	swift build $(RELEASE_FLAGS)

run: ## Build and run (debug)
run: build
	swift run $(SWIFT_BUILD_FLAGS) spacebar

run.json: ## Build and run with JSON output
run.json: build
	swift run $(SWIFT_BUILD_FLAGS) spacebar --json

app: ## Build .app bundle (required for cross-space window activation)
app: build
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp .build/debug/spacebar $(APP_BUNDLE)/Contents/MacOS/spacebar
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign "Spacebar Dev" $(APP_BUNDLE)

run.activate: ## Activate a window by ID (usage: make run.activate ID=<window-id>)
run.activate: app
	open -n -W --stdout `tty` --stderr `tty` $(APP_BUNDLE) --args activate $(ID)

build-gui: ## Build GUI target (debug)
	swift build $(DEBUG_FLAGS) --product spacebar-gui

app-gui: ## Build .app bundle with GUI executable
app-gui: kill build-gui
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp .build/debug/spacebar-gui $(APP_BUNDLE)/Contents/MacOS/spacebar
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign "Spacebar Dev" $(APP_BUNDLE)

gui: ## Build and run the GUI window switcher
gui: app-gui
	open -n --stdout `tty` --stderr `tty` $(APP_BUNDLE)

kill: ## Kill running Spacebar app
	@pkill -f "Spacebar.app" 2>/dev/null || true

clean: ## Clean build artifacts
	swift package clean
	rm -rf .build dist

test: ## Run tests
	swift test $(SWIFT_BUILD_FLAGS)

format: ## Format code (requires swift-format)
	swift-format -i -r Sources/ Tests/

lint: ## Lint code (requires swift-format)
	swift-format lint -r Sources/ Tests/

install: ## Install to PREFIX (default /usr/local)
install: release
	@echo "Installing spacebar to $(PREFIX)/bin..."
	@mkdir -p $(PREFIX)/bin
	@if [ -w $(PREFIX)/bin ]; then \
		cp .build/release/spacebar $(PREFIX)/bin/spacebar; \
	else \
		sudo cp .build/release/spacebar $(PREFIX)/bin/spacebar; \
	fi
	@echo "Installed! Run 'spacebar --help' to get started."
