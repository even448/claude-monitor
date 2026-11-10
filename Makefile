.PHONY: build run test icon clean

build:
	./scripts/build-app.sh

run: build
	open build/ClaudeMonitor.app

test:
	./scripts/smoke-test.sh

icon:
	python3 scripts/make-icon.py
	iconutil -c icns /tmp/ClaudeMonitor.iconset -o Resources/AppIcon.icns

clean:
	rm -rf .build .build-check .clang-build build/tests
