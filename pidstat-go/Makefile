GO ?= go

.PHONY: check-go test build

check-go:
	@test "$$($(GO) env GOVERSION)" = "go1.27.3" || { echo 'Use the pinned Go 1.27.3 toolchain' >&2; exit 1; }

test: check-go
	GOTOOLCHAIN=local CGO_ENABLED=0 $(GO) test -v ./...
	GOTOOLCHAIN=local CGO_ENABLED=0 $(GO) vet ./...
	GOTOOLCHAIN=local $(GO) mod verify

build: check-go
	mkdir -p bin
	GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -trimpath -o bin/pidstat-parquet-spike-linux-arm64 .
	GOTOOLCHAIN=local CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64=v1 $(GO) build -trimpath -o bin/pidstat-parquet-spike-linux-amd64 .
