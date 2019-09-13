#!/usr/bin/env bash

GO_VERSION=1.12
if [[ "$FLAG_TAGS" =~ (go=([^,]*))(.*) ]]; then
    GO_VERSION=${BASH_REMATCH[2]}
fi
echo "Custom Go version detected: $GO_VERSION"
export FLAG_TAGS=${BASH_REMATCH[3]}

set -ex

export ROOT_DIST="https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz"
wget -qO /tmp/download "$ROOT_DIST"  # hack to get around predefined checksums from base xgo
export ROOT_DIST_SHA=$(sha1sum /tmp/download)
rm /tmp/download

if [[ "$GO_VERSION" =~ [0-9]+\.[0-9]+ ]]; then
    GO_VERSION+=.0  # used in old compatibility checks so patch version won't matter
fi
export GO_VERSION=${GO_VERSION//./}

$BOOTSTRAP_PURE


exec /build.sh "$@"
