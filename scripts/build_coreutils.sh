#!/bin/bash
set -e

BUILD_DIR="vendor/coreutils"
INSTALL_DIR="{$1:-zig-out/programs}"

# make sure submodules are initialized
cd "$BUILD_DIR"

# only bootstrap/configure if not already done
if [ ! -f "Makefile" ]; then
    echo "Bootstrapping..."
    ./bootstrap

    echo "Configuring..."
    ./configure \
        --prefix=/usr \
        --disable-nls \
        --disable-acl \
        --disable-xattr \
        --disable-libcap \
        --without-gmp \
        CC=musl-gcc \
        LDFLAGS="-static"
fi

echo "Building..."
make -j$(nproc)

cd ../..

mkdir -p "$INSTALL_DIR"

UTILS=(
    ls cat echo cp mv rm mkdir rmdir
    pwd touch chmod chown ln stat
    wc head tail cut sort uniq
    find xargs tee
    true false yes
    du df date uname
    id whoami env printenv
)

for util in "${UTILS[@]}"; do
    src="$BUILD_DIR/src/$util"
    if [ -f "$src" ]; then
        cp "$src" "$INSTALL_DIR/$util"
        echo "  copied $util"
    else
        echo "  WARNING: $util not found"
    fi
done

echo "Done!"
