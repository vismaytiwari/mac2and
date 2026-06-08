.PHONY: build app test check install-agent uninstall-agent clean

build:
	swift build

app:
	./scripts/build-app.sh

test:
	swift run Mac2And --self-test

check:
	./scripts/check-open-source-ready.sh

install-agent:
	./scripts/install-launchagent.sh

uninstall-agent:
	./scripts/uninstall-launchagent.sh

clean:
	rm -rf .build dist
