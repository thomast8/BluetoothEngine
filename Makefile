.PHONY: build clean

build:
	swift build
	mkdir -p dist
	cp .build/debug/sensor .build/debug/sensor-debug dist/

clean:
	rm -rf .build dist
