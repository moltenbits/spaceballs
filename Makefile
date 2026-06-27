.PHONY: help all build release bundle bundle-release dist notarize clean test run run.json everything format lint install uninstall bootstrap brewfile kill

# Build configuration
SWIFT_BUILD_FLAGS = --disable-sandbox
RELEASE_FLAGS = -c release $(SWIFT_BUILD_FLAGS)
DEBUG_FLAGS = -c debug $(SWIFT_BUILD_FLAGS)
PREFIX ?= /usr/local
APP_INSTALL_PATH ?= /Applications
BIN_INSTALL_PATH = $(PREFIX)/bin
LIB_INSTALL_PATH = $(PREFIX)/lib/spaceballs
GUI_APP_RELEASE = .build/release/Spaceballs.app
CLI_APP_RELEASE = .build/release/Spaceballs-CLI.app

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

all: ## Default target
all: bundle

bootstrap: ## Install required tooling
bootstrap: brewfile

brewfile:
	@brew bundle install

build: ## Build debug executables only
	swift build $(DEBUG_FLAGS)

release: ## Build release executables only
	swift build $(RELEASE_FLAGS)

bundle: ## Build debug GUI and CLI app bundles
	./scripts/bundle.sh debug

bundle-release: ## Build release GUI and CLI app bundles
	./scripts/bundle.sh release

dist: ## Build distributable archive, notarizing when credentials are configured
	@if [ -n "$(VERSION)" ]; then \
		./scripts/release.sh "$(VERSION)"; \
	else \
		./scripts/release.sh; \
	fi

notarize: ## Alias for dist; scripts/release.sh notarizes when credentials are configured
notarize: dist

everything: ## Kill + release bundle + install + open the installed GUI app
everything: kill install
	@open -n "$(APP_INSTALL_PATH)/Spaceballs.app"

run: ## Build + run CLI (text output)
	swift build $(DEBUG_FLAGS) --product spaceballs
	swift run $(SWIFT_BUILD_FLAGS) spaceballs

run.json: ## Build + run CLI (JSON output)
	swift build $(DEBUG_FLAGS) --product spaceballs
	swift run $(SWIFT_BUILD_FLAGS) spaceballs --json

kill: ## Kill running Spaceballs.app
	@pkill -INT -f "Spaceballs.app" 2>/dev/null || true
	@sleep 1

clean: ## Remove build artifacts
	swift package clean
	rm -rf .build dist

test: ## Run tests
	swift test $(SWIFT_BUILD_FLAGS)

format: ## Format code
	swift-format -i -r Sources/ Tests/

lint: ## Lint code
	swift-format lint -r Sources/ Tests/

install: ## Install app bundles and CLI symlink (may require sudo)
install: bundle-release
	@echo "Installing Spaceballs.app to $(APP_INSTALL_PATH)..."
	@if [ -w "$(APP_INSTALL_PATH)" ]; then \
		rm -rf "$(APP_INSTALL_PATH)/Spaceballs.app"; \
		cp -R "$(GUI_APP_RELEASE)" "$(APP_INSTALL_PATH)/"; \
	else \
		sudo rm -rf "$(APP_INSTALL_PATH)/Spaceballs.app"; \
		sudo cp -R "$(GUI_APP_RELEASE)" "$(APP_INSTALL_PATH)/"; \
	fi
	@echo "Installing Spaceballs-CLI.app to $(LIB_INSTALL_PATH)..."
	@if [ -w "$(PREFIX)" ]; then \
		mkdir -p "$(LIB_INSTALL_PATH)"; \
		rm -rf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app"; \
		cp -R "$(CLI_APP_RELEASE)" "$(LIB_INSTALL_PATH)/"; \
		mkdir -p "$(BIN_INSTALL_PATH)"; \
		ln -sf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app/Contents/MacOS/spaceballs" "$(BIN_INSTALL_PATH)/spaceballs"; \
	else \
		sudo mkdir -p "$(LIB_INSTALL_PATH)" "$(BIN_INSTALL_PATH)"; \
		sudo rm -rf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app"; \
		sudo cp -R "$(CLI_APP_RELEASE)" "$(LIB_INSTALL_PATH)/"; \
		sudo ln -sf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app/Contents/MacOS/spaceballs" "$(BIN_INSTALL_PATH)/spaceballs"; \
	fi
	@echo "Installed! Run 'hash -r' to refresh your shell, then 'spaceballs --help' to get started."

uninstall: ## Uninstall app bundles and CLI symlink (may require sudo)
	@rm -f "$(BIN_INSTALL_PATH)/spaceballs" 2>/dev/null || \
		sudo rm -f "$(BIN_INSTALL_PATH)/spaceballs"
	@rm -rf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app" 2>/dev/null || \
		sudo rm -rf "$(LIB_INSTALL_PATH)/Spaceballs-CLI.app"
	@rm -rf "$(APP_INSTALL_PATH)/Spaceballs.app" 2>/dev/null || \
		sudo rm -rf "$(APP_INSTALL_PATH)/Spaceballs.app"
	@echo "Uninstalled Spaceballs"
