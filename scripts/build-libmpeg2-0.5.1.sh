#!/opt/tigersh-deps-0.1/bin/bash
# Build libmpeg2 0.5.1 as a static library on Tiger / PowerPC.
# Based on templates/build-from-source.sh v6 from leopard.sh.
#
# This is a throwaway build helper for TigerTube, not committed to leopard.sh.
# Run on imacg3:
#   /Users/macuser/tmp/build-libmpeg2-0.5.1.sh > /Users/macuser/tmp/build-libmpeg2.log 2>&1 &
#
# After a successful build, the install tree is at:
#   /Users/macuser/tmp/libmpeg2-install/usr/local/{lib,include}
#
# Rsync back to the main Mac with:
#   ~/bin/tiger-rsync.sh --delete \
#       imacg3:/Users/macuser/tmp/libmpeg2-install/usr/local/ \
#       ~/github/cellularmitosis/TigerTube/libs/libmpeg2/

set -e -o pipefail

package=libmpeg2
version=0.5.1
tarball=/Users/macuser/tmp/${package}-${version}.tar.gz

SRCDIR=/Users/macuser/tmp/${package}-${version}
DESTDIR=/Users/macuser/tmp/libmpeg2-install
PREFIX=/usr/local

echo "=== build-libmpeg2 starting at $(date) ==="
echo "tarball: $tarball"
echo "srcdir:  $SRCDIR"
echo "DESTDIR: $DESTDIR"
echo "PREFIX:  $PREFIX"

# --- unpack ---

if test -d "$SRCDIR"; then
    echo "Removing old source tree..."
    rm -rf "$SRCDIR"
fi

echo "Unpacking..."
cd /Users/macuser/tmp
tar xzf "$tarball"

cd "$SRCDIR"
echo "Source unpacked to $(pwd)"

# --- configure ---

# gcc-4.0 is the stock Xcode 2.5 compiler, paired with MacOSX10.4u.sdk.
# -mcpu=750 targets the G3 (no AltiVec).  -fno-strict-aliasing because
# mpeg2dec does some aliasing games in decode.c / slice.c.
# Configure will auto-detect AltiVec but the runtime detection in
# ACCEL_DETECT will skip it on G3, so it's harmless to compile.
export CC=/usr/bin/gcc-4.0
export CFLAGS="-O2 -mcpu=750 -fno-strict-aliasing"

echo "=== configure starting at $(date) ==="
/usr/bin/time ./configure \
    --prefix="$PREFIX" \
    --disable-shared \
    --enable-static \
    --disable-sdl \
    --without-x \
    --disable-debug

echo "=== configure finished at $(date) ==="

# --- build ---

echo "=== make starting at $(date) ==="
/usr/bin/time make -j1 V=1
echo "=== make finished at $(date) ==="

# --- install into DESTDIR ---

if test -d "$DESTDIR"; then
    rm -rf "$DESTDIR"
fi
mkdir -p "$DESTDIR"

echo "=== make install starting at $(date) ==="
make install DESTDIR="$DESTDIR"
echo "=== make install finished at $(date) ==="

# --- verify ---

echo ""
echo "=== installed files ==="
find "$DESTDIR" -type f | sort
echo ""

# Quick sanity: is libmpeg2.a present and a valid ppc archive?
LIBFILE="$DESTDIR$PREFIX/lib/libmpeg2.a"
if test -f "$LIBFILE"; then
    echo "libmpeg2.a: $(file "$LIBFILE")"
    echo "libmpeg2.a symbols:"
    nm "$LIBFILE" | grep " T _mpeg2_" | head -10
else
    echo "ERROR: $LIBFILE not found!"
    exit 1
fi

LIBCONVERT="$DESTDIR$PREFIX/lib/libmpeg2convert.a"
if test -f "$LIBCONVERT"; then
    echo "libmpeg2convert.a: $(file "$LIBCONVERT")"
else
    echo "ERROR: $LIBCONVERT not found!"
    exit 1
fi

echo ""
echo "=== build-libmpeg2 finished successfully at $(date) ==="
echo "Next step: from main Mac, rsync back with:"
echo '  ~/bin/tiger-rsync.sh --delete \'
echo '      imacg3:/Users/macuser/tmp/libmpeg2-install/usr/local/ \'
echo '      ~/github/cellularmitosis/TigerTube/libs/libmpeg2/'
