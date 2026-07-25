APP=nanopi-webui
PREFIX?=/usr/local
BIN=$(PREFIX)/bin/$(APP)
DIST=dist/$(APP)
VERSION_FILE?=../VERSION
export GOMAXPROCS?=2
export GOTOOLCHAIN?=local

# Однозначная версия: из VERSION (vX.Y.Z) или VERSION=v… в окружении
RAW_VER=$(shell tr -d '[:space:]' < $(VERSION_FILE) 2>/dev/null)
ifeq ($(RAW_VER),)
RAW_VER=dev
endif
ifeq ($(filter v%,$(RAW_VER)),)
VERSION?=v$(RAW_VER)
else
VERSION?=$(RAW_VER)
endif

LDFLAGS=-s -w -X main.Version=$(VERSION)

GOOS?=
GOARCH?=
GO_ENV=
ifneq ($(GOOS),)
GO_ENV+=GOOS=$(GOOS)
endif
ifneq ($(GOARCH),)
GO_ENV+=GOARCH=$(GOARCH)
endif

.PHONY: build build-arm64 install install-unit clean

build:
	mkdir -p dist
	@echo "building $(APP) $(VERSION)"
	$(GO_ENV) go build -trimpath -ldflags='$(LDFLAGS)' -o $(DIST) .

build-arm64:
	$(MAKE) build GOOS=linux GOARCH=arm64

install: build
	install -m 755 $(DIST) $(BIN)

install-unit:
	install -m 644 nanopi-webui.service /etc/systemd/system/nanopi-webui.service
	systemctl daemon-reload
	systemctl enable --now nanopi-webui

clean:
	rm -rf dist
