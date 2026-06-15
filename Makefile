APP         := ClaudeUsage
BUNDLE      := $(APP).app
BUNDLE_ID   := com.rodolfoquendo.claudeusage
INSTALL_DIR := /Applications
INSTALLED   := $(INSTALL_DIR)/$(BUNDLE)
PLIST       := $(HOME)/Library/LaunchAgents/$(BUNDLE_ID).plist

.PHONY: help build open run install autostart unautostart status clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

build: ## Compile and assemble ClaudeUsage.app
	./build.sh

open: build ## Build, then launch the app from this folder
	open $(BUNDLE)

run: open ## Alias for `open`

install: build ## Copy the app into /Applications
	rm -rf "$(INSTALLED)"
	cp -r $(BUNDLE) "$(INSTALL_DIR)/"
	@echo "==> Installed to $(INSTALLED)"

autostart: install ## Install + start at every login (LaunchAgent), and start now
	mkdir -p "$(HOME)/Library/LaunchAgents"
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>Label</key><string>$(BUNDLE_ID)</string>' \
		'  <key>ProgramArguments</key>' \
		'  <array>' \
		'    <string>$(INSTALLED)/Contents/MacOS/$(APP)</string>' \
		'  </array>' \
		'  <key>RunAtLoad</key><true/>' \
		'  <key>ProcessType</key><string>Interactive</string>' \
		'</dict>' \
		'</plist>' > "$(PLIST)"
	launchctl bootout gui/$$(id -u)/$(BUNDLE_ID) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) "$(PLIST)"
	launchctl kickstart -k gui/$$(id -u)/$(BUNDLE_ID)
	@echo "==> Autostart enabled. Running now and at every login."

unautostart: ## Stop autostart and remove the LaunchAgent
	launchctl bootout gui/$$(id -u)/$(BUNDLE_ID) 2>/dev/null || true
	rm -f "$(PLIST)"
	@echo "==> Autostart disabled."

status: ## Show whether the app is running / registered
	@pgrep -x $(APP) >/dev/null && echo "running (pid $$(pgrep -x $(APP)))" || echo "not running"
	@launchctl print gui/$$(id -u)/$(BUNDLE_ID) >/dev/null 2>&1 && echo "autostart: enabled" || echo "autostart: disabled"

clean: ## Remove build artifacts
	rm -rf .build $(BUNDLE)
