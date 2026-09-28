CC ?= gcc
CFLAGS += $(shell pkg-config --cflags gtk+-3.0) -O2 -Wall
LIBS += $(shell pkg-config --libs gtk+-3.0) -lpthread

boreal-installer: boreal-installer.c
	$(CC) $(CFLAGS) -o boreal-installer boreal-installer.c $(LIBS)

install: boreal-installer
	install -Dm755 boreal-installer /usr/local/bin/boreal-installer
	install -Dm644 style.css /usr/share/boreal-installer/style.css

clean:
	rm -f boreal-installer
