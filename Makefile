.PHONY: build test bundle run clean
.PHONY: package
.PHONY: install

build:
	./scripts/build.sh debug

test:
	swift run BudsSelfTest

bundle:
	./scripts/bundle.sh release

package:
	./scripts/package.sh release

install:
	./scripts/install.sh release

run:
	./scripts/run.sh

clean:
	rm -rf .build dist
