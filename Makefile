.PHONY: help dev app universal screenshots icons clean

help:
	@echo "make dev         - run DockPane with 'swift run' (development)"
	@echo "make screenshots - render the README panel screenshot → docs/screenshot.png"
	@echo "make app         - build dist/DockPane.app and the .zip for GitHub Releases"
	@echo "make universal   - same as 'make app', universal arm64 + x86_64 binary (requires full Xcode)"
	@echo "make icons       - regenerate the logo and AppIcon.icns"
	@echo "make clean       - remove build artifacts"

dev:
	swift run DockPane

screenshots:
	@mkdir -p docs
	swift build
	DOCKPANE_SHOT=$(CURDIR)/docs/screenshot.png "$$(swift build --show-bin-path)/DockPane"

app:
	./scripts/package-macos.sh

universal:
	UNIVERSAL=1 ./scripts/package-macos.sh

icons:
	./branding/make-icons.sh

clean:
	rm -rf dist .build
