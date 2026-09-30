.PHONY: build test install uninstall clean

build:
	./Scripts/build-app.sh

test:
	./Scripts/swift.sh run $(SWIFT_FLAGS) WebTimeSelfTest
	bash Scripts/test-dns-service.sh $(SWIFT_FLAGS)
	bash Scripts/test-legacy-dns.sh

install: build
	./Scripts/install.sh

uninstall:
	./Scripts/uninstall.sh

clean:
	./Scripts/swift.sh package clean
