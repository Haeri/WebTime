.PHONY: build test install uninstall clean

build:
	./Scripts/build-app.sh

test:
	./Scripts/swift.sh run WebTimeSelfTest

install: build
	./Scripts/install.sh

uninstall:
	./Scripts/uninstall.sh

clean:
	./Scripts/swift.sh package clean
