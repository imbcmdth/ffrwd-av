#!/bin/sh
# Builds LGPL-only shared libavutil, libswresample, libavcodec and libswscale
# for one platform of the ffrwd sidecar wheel, and packs them with the LGPL
# text into dist/ffrwd-av-<tag>-<platform>.tar.gz.
#
# Usage: sh scripts/build.sh <platform> <tag>
#
# The Linux platforms run inside their manylinux or musllinux container,
# windows-x86_64 in an MSYS2 UCRT64 shell, and macos-aarch64 and
# windows-aarch64 directly on the runner. Run it from the repository root.
set -eu

# Sources, each pinned by version and checksum.
FFMPEG_TAG=n9.0.1
FFMPEG_URL=https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz
FFMPEG_SHA256=cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635

# nv-codec-headers publishes no checksum for this release, so it is cloned
# at the tag and checked against the tag's commit.
NVCODEC_TAG=n12.1.14.0
NVCODEC_COMMIT=1889e62e2d35ff7aa9baca2bceb14f053785e6f1
NVCODEC_REPO=https://github.com/FFmpeg/nv-codec-headers.git

AMF_URL=https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.5.2/AMF-headers-v1.5.2.tar.gz
AMF_SHA256=d3c12eb324edf05e214608b6a395a51dd95770ed9d45520185d6c3a206811c99

LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260616/llvm-mingw-20260616-ucrt-ubuntu-22.04-x86_64.tar.xz
LLVM_MINGW_SHA256=534b92e067b22a6b4441f48ae9240a3341b17825d04d577eab0cf85c44b4deda

# The library majors the archive's file names carry. Checked against the
# FFmpeg source before anything is built.
MAJORS="avutil:61 swresample:7 avcodec:63 swscale:10"

DECODERS=h264,hevc,av1,vp9,mpeg2video,prores,mjpeg,ffv1,mpeg4
PARSERS=h264,hevc,av1,vp9,mpegvideo,mjpeg,mpeg4video
BSFS=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata
ENCODERS=ffv1,mpeg4,mpeg2video,mjpeg

die() {
    echo "build.sh: $*" >&2
    exit 1
}

# A GitHub annotation in Actions, a plain line elsewhere.
warn() {
    echo "::warning::$*"
}

[ $# -eq 2 ] || die "usage: sh scripts/build.sh <platform> <tag>"
platform=$1
tag=$2

case $platform in
    manylinux-x86_64 | manylinux-aarch64 | musllinux-x86_64 | musllinux-aarch64 | macos-aarch64 | windows-x86_64 | windows-aarch64) ;;
    *) die "unknown platform $platform" ;;
esac

root=$(pwd)
work=$root/build/$platform
src=$work/ffmpeg
prefix=$work/prefix
deps=$work/deps
dist=$root/dist
name=ffrwd-av-$tag-$platform
rm -rf "$work"
mkdir -p "$work" "$deps" "$dist"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# fetch <url> <sha256> <file>
fetch() {
    echo "fetching $1"
    curl -fsSL --retry 3 --retry-delay 5 -o "$3" "$1"
    got=$(sha256 "$3")
    [ "$got" = "$2" ] || die "$1: sha256 is $got, pinned $2"
}

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# Single-quotes an argument when the shell would otherwise read it
# differently, so the recorded configure line can be pasted back.
quote() {
    case $1 in
        '' | *[!A-Za-z0-9_./=,:@+-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The file name each library carries on this platform.
libname() {
    case $platform in
        manylinux-* | musllinux-*) echo "lib$1.so.$2" ;;
        macos-*) echo "lib$1.$2.dylib" ;;
        windows-*) echo "$1-$2.dll" ;;
    esac
}

# --- Build tools ------------------------------------------------------------

case $platform in
    manylinux-*)
        dnf install -y make pkgconfig xz git binutils
        if [ "$platform" = manylinux-x86_64 ]; then
            dnf install -y nasm || dnf install -y --enablerepo=powertools nasm
        fi
        # Missing or too old, the vulkan headers drop vulkan from this build
        # rather than failing it; configure decides below.
        dnf install -y vulkan-headers || warn "vulkan-headers is not installable in this image"
        ;;
    musllinux-*)
        apk add --no-cache make pkgconf xz tar curl binutils
        if [ "$platform" = musllinux-x86_64 ]; then
            apk add --no-cache nasm
        fi
        ;;
    windows-aarch64)
        command -v pkg-config >/dev/null 2>&1 || {
            sudo apt-get update
            sudo apt-get install -y pkg-config
        }
        fetch "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256" "$work/llvm-mingw.tar.xz"
        mkdir -p "$work/llvm-mingw"
        tar -xf "$work/llvm-mingw.tar.xz" -C "$work/llvm-mingw" --strip-components=1
        PATH=$work/llvm-mingw/bin:$PATH
        export PATH
        ;;
esac

# MSYS2's pkgconf and gcc search the environment's own prefix, so the
# headers go there on windows-x86_64; everywhere else they stay in deps/.
if [ "$platform" = windows-x86_64 ]; then
    deps=$MINGW_PREFIX
fi

# --- Sources ----------------------------------------------------------------

fetch "$FFMPEG_URL" "$FFMPEG_SHA256" "$work/ffmpeg.tar.xz"
mkdir -p "$src"
tar -xf "$work/ffmpeg.tar.xz" -C "$src" --strip-components=1

for pair in $MAJORS; do
    lib=${pair%%:*}
    want=${pair#*:}
    # libavutil defines its major in version.h; the others in version_major.h.
    got=""
    for header in "$src/lib$lib/version_major.h" "$src/lib$lib/version.h"; do
        [ -f "$header" ] || continue
        got=$(sed -n "s/^#define LIB$(upper "$lib")_VERSION_MAJOR[[:space:]][[:space:]]*\([0-9][0-9]*\).*/\1/p" "$header")
        [ -z "$got" ] || break
    done
    [ "$got" = "$want" ] || die "lib$lib major is '$got' in $FFMPEG_TAG, expected $want"
done

case $platform in
    manylinux-* | windows-*)
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$NVCODEC_TAG" "$NVCODEC_REPO" "$work/nv-codec-headers"
        got=$(git -C "$work/nv-codec-headers" rev-parse HEAD)
        [ "$got" = "$NVCODEC_COMMIT" ] || die "nv-codec-headers $NVCODEC_TAG is $got, pinned $NVCODEC_COMMIT"
        make -C "$work/nv-codec-headers" PREFIX="$deps" install
        ;;
esac

if [ "$platform" = windows-x86_64 ]; then
    fetch "$AMF_URL" "$AMF_SHA256" "$work/amf.tar.gz"
    mkdir -p "$work/amf"
    tar -xzf "$work/amf.tar.gz" -C "$work/amf"
    # FFmpeg includes <AMF/core/...>; the archive's own layout may nest that
    # directory, so it is found by its contents.
    factory=$(find "$work/amf" -path '*/core/Factory.h' | head -n 1)
    [ -n "$factory" ] || die "no core/Factory.h in the AMF headers archive"
    amf_include=$(dirname "$(dirname "$factory")")
    mkdir -p "$deps/include/AMF"
    cp -R "$amf_include/." "$deps/include/AMF/"
fi

if [ "$platform" = windows-aarch64 ]; then
    # Only the pinned headers, never the build machine's .pc files.
    PKG_CONFIG_LIBDIR=$deps/lib/pkgconfig
    export PKG_CONFIG_LIBDIR
elif [ "$platform" != windows-x86_64 ]; then
    PKG_CONFIG_PATH=$deps/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
    export PKG_CONFIG_PATH
fi

# --- Configure --------------------------------------------------------------

# --disable-autodetect also turns off the threading library, so each
# platform names its own. hwaccels and hardware encoders are comma lists;
# hw_apis are the matching --enable-<api> flags.
hw_apis=""
hwaccels=""
hwencoders=""
# APIs whose headers come from the image's package manager and may be
# dropped when configure cannot find them.
droppable=""
platform_args=""

add() {
    for a in "$@"; do
        platform_args="$platform_args $(quote "$a")"
    done
}

# -Wl,-rpath,$ORIGIN for the Linux builds. Each $ is expanded three times
# before the linker sees it: by configure's eval, then twice by make, since
# library.mak's link rule is a $(eval) template whose LDFLAGS is expanded
# once when the template is evaluated and again when the recipe runs. So
# configure is given \$\$\$\$, writes $$$$ to config.mak, and the single
# quotes keep the shell from reading the $ORIGIN make leaves.
q="'"
rpath_origin="-Wl,-rpath,${q}\\\$\\\$\\\$\\\$ORIGIN${q}"
case $platform in
    manylinux-*)
        # No vaapi: libavutil would link libva at load time and then not
        # load at all on a machine without it.
        hw_apis="ffnvcodec cuda nvdec nvenc vulkan"
        hwaccels=h264_nvdec,hevc_nvdec,av1_nvdec,vp9_nvdec,mpeg2_nvdec,h264_vulkan,hevc_vulkan,av1_vulkan
        hwencoders=h264_nvenc,hevc_nvenc,av1_nvenc
        droppable="vulkan"
        add --enable-pthreads "--extra-ldflags=$rpath_origin"
        ;;
    musllinux-*)
        add --enable-pthreads "--extra-ldflags=$rpath_origin"
        ;;
    macos-aarch64)
        hw_apis="videotoolbox"
        hwaccels=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox
        hwencoders=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox
        add --enable-pthreads --install-name-dir=@rpath \
            --extra-cflags=-mmacosx-version-min=11.0 \
            --extra-ldflags=-mmacosx-version-min=11.0 \
            --extra-ldflags=-Wl,-rpath,@loader_path
        ;;
    windows-*)
        hw_apis="ffnvcodec cuda nvdec nvenc d3d11va d3d12va dxva2 mediafoundation"
        hwaccels=h264_d3d11va,hevc_d3d11va,av1_d3d11va,vp9_d3d11va,mpeg2_d3d11va,h264_d3d12va,hevc_d3d12va,av1_d3d12va,vp9_d3d12va,mpeg2_d3d12va,h264_dxva2,hevc_dxva2,h264_nvdec,hevc_nvdec,av1_nvdec,vp9_nvdec,mpeg2_nvdec
        hwencoders=h264_nvenc,hevc_nvenc,av1_nvenc
        if [ "$platform" = windows-x86_64 ]; then
            hw_apis="$hw_apis amf"
            hwencoders=$hwencoders,h264_amf,hevc_amf,av1_amf
        fi
        hwencoders=$hwencoders,h264_mf,hevc_mf
        # -static keeps libgcc, libwinpthread and their llvm-mingw
        # counterparts inside the DLLs instead of beside them.
        add --enable-w32threads --extra-ldflags=-static
        if [ "$platform" = windows-aarch64 ]; then
            add --enable-cross-compile --arch=aarch64 --target-os=mingw32 \
                --cross-prefix=aarch64-w64-mingw32- --cc=aarch64-w64-mingw32-clang \
                --pkg-config=pkg-config
        fi
        ;;
esac

dropped=""

# drop <api>: removes the API and every hwaccel and encoder named after it.
drop() {
    kept=""
    for a in $hw_apis; do
        [ "$a" = "$1" ] || kept="$kept $a"
    done
    hw_apis=${kept# }
    hwaccels=$(printf '%s' "$hwaccels" | tr ',' '\n' | grep -v "_$1\$" | tr '\n' ',' | sed 's/,$//')
    hwencoders=$(printf '%s' "$hwencoders" | tr ',' '\n' | grep -v "_$1\$" | tr '\n' ',' | sed 's/,$//')
    dropped="$dropped $1"
}

configure_line() {
    line=$(quote "--prefix=$prefix")
    for a in --disable-everything --disable-programs --disable-doc \
        --disable-static --enable-shared \
        --disable-avformat --disable-avfilter --disable-avdevice \
        --enable-swscale --enable-swresample \
        --disable-network --disable-autodetect --enable-pic \
        "--enable-decoder=$DECODERS" "--enable-parser=$PARSERS" \
        "--enable-bsf=$BSFS" "--enable-encoder=$ENCODERS"; do
        line="$line $(quote "$a")"
    done
    for a in $hw_apis; do
        line="$line --enable-$a"
    done
    [ -z "$hwaccels" ] || line="$line $(quote "--enable-hwaccel=$hwaccels")"
    [ -z "$hwencoders" ] || line="$line $(quote "--enable-encoder=$hwencoders")"
    printf '%s%s' "$line" "$platform_args"
}

cd "$src"
while :; do
    args=$(configure_line)
    echo "./configure $args"
    if eval "./configure $args" >"$work/configure.out" 2>&1; then
        break
    fi
    missing=$(sed -n 's/^ERROR: \([a-z0-9_]*\) requested but not found$/\1/p' "$work/configure.out")
    case " $droppable " in
        *" $missing "*)
            if [ -n "$missing" ]; then
                warn "$platform: configure found no $missing headers; building without $missing"
                drop "$missing"
                continue
            fi
            ;;
    esac
    cat "$work/configure.out"
    tail -n 60 ffbuild/config.log || true
    die "configure failed"
done
cat "$work/configure.out"

# Every software component must be in; a hardware one configure turned off
# for a missing type or struct is reported and recorded.
disabled=""
check_components() {
    kind=$1
    list=$2
    required=$3
    for c in $(printf '%s' "$list" | tr ',' ' '); do
        if ! grep -q "^#define CONFIG_$(upper "${c}_$kind") 1\$" config_components.h; then
            [ "$required" = required ] && die "configure disabled the ${c} $kind"
            warn "$platform: configure disabled the ${c} $kind"
            disabled="$disabled ${c}_$kind"
        fi
    done
}
check_components decoder "$DECODERS" required
check_components parser "$PARSERS" required
check_components bsf "$BSFS" required
check_components encoder "$ENCODERS" required
check_components hwaccel "$hwaccels" optional
check_components encoder "$hwencoders" optional

# --- Build ------------------------------------------------------------------

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
make -j"$jobs"
make install
cd "$root"

# --- Collect and check ------------------------------------------------------

stage=$work/stage/$name
mkdir -p "$stage"
siblings=""
for pair in $MAJORS; do
    siblings="$siblings $(libname "${pair%%:*}" "${pair#*:}")"
done

for lib in $siblings; do
    found=""
    for dir in "$prefix/lib" "$prefix/bin"; do
        if [ -e "$dir/$lib" ]; then
            found=$dir/$lib
        fi
    done
    [ -n "$found" ] || die "make install produced no $lib"
    cp -L "$found" "$stage/$lib"
done

is_sibling() {
    case " $siblings " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Each library must name its siblings by the file names above, find them
# beside itself, and need nothing a wheel cannot assume is installed.
for lib in $siblings; do
    f=$stage/$lib
    case $platform in
        manylinux-* | musllinux-*)
            soname=$(readelf -d "$f" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
            [ "$soname" = "$lib" ] || die "$lib has soname $soname"
            runpath=$(readelf -d "$f" | sed -n 's/.*(R[UN]*PATH).*\[\(.*\)\]/\1/p')
            # shellcheck disable=SC2016
            [ "$runpath" = '$ORIGIN' ] || die "$lib has runpath '$runpath', not \$ORIGIN"
            for dep in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
                echo "$lib needs $dep"
                case $dep in
                    libc.so | libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | libgcc_s.so.1 | ld-linux* | libc.musl-* | ld-musl-*) ;;
                    *) is_sibling "$dep" || die "$lib needs $dep" ;;
                esac
            done
            ;;
        macos-*)
            id=$(otool -D "$f" | sed -n 2p)
            [ "$id" = "@rpath/$lib" ] || die "$lib has install name $id"
            otool -l "$f" | grep -A2 LC_RPATH | grep -q 'path @loader_path ' || die "$lib has no @loader_path rpath"
            for dep in $(otool -L "$f" | sed 1d | awk '{print $1}'); do
                echo "$lib needs $dep"
                case $dep in
                    /usr/lib/* | /System/Library/*) ;;
                    @rpath/*) is_sibling "${dep#@rpath/}" || die "$lib needs $dep" ;;
                    *) die "$lib needs $dep" ;;
                esac
            done
            ;;
        windows-*)
            objdump=objdump
            [ "$platform" = windows-aarch64 ] && objdump=aarch64-w64-mingw32-objdump
            for dep in $("$objdump" -p "$f" | sed -n 's/.*DLL Name: *//p' | tr -d '\r'); do
                echo "$lib needs $dep"
                # System DLLs and the siblings only; a toolchain runtime
                # (libgcc_s, libwinpthread, libunwind, libc++) starts with lib.
                case $(printf '%s' "$dep" | tr '[:upper:]' '[:lower:]') in
                    lib*) die "$lib needs $dep" ;;
                esac
            done
            ;;
    esac
done

cp "$src/COPYING.LGPLv2.1" "$stage/COPYING.LGPLv2.1"

# Prints a header's leading comment block without its comment markers:
# a /* */ block or a run of // lines. Carriage returns and a byte-order mark
# before the first comment are removed first.
leading_comment() {
    tr -d '\r' <"$1" | LC_ALL=C sed '1s/^[^/]*//' | awk '
        NR == 1 && /^\/\*/ { style = "block" }
        NR == 1 && /^\/\// { style = "line" }
        style == "block" {
            last = ($0 ~ /\*\//)
            line = $0
            sub(/^\/\*+ ?/, "", line)
            sub(/^ *\*\/.*$/, "", line)
            sub(/^ *\* ?/, "", line)
            print line
            if (last) exit
            next
        }
        style == "line" {
            if ($0 !~ /^\/\//) exit
            line = $0
            sub(/^\/\/ ?/, "", line)
            print line
            next
        }
        { exit }
    '
}

# notices <title> <header dir> <out>: writes each distinct MIT notice the
# headers under the directory carry, with the headers that carry it. The
# headers' code (NVIDIA's and AMD's runtime loaders) is compiled into the
# libraries, so their notices travel with them.
notices() {
    tmp=$work/notices
    rm -rf "$tmp"
    mkdir -p "$tmp"
    find "$2" -name '*.h' | sort | while IFS= read -r header; do
        leading_comment "$header" >"$tmp/notice"
        grep -q 'Permission is hereby granted' "$tmp/notice" || continue
        key=$(cksum <"$tmp/notice" | cut -d' ' -f1)
        [ -e "$tmp/$key.txt" ] || cp "$tmp/notice" "$tmp/$key.txt"
        echo "${header#"$2"/}" >>"$tmp/$key.files"
    done
    {
        echo "Code from $1 is compiled into these libraries. Its headers carry the notices below."
        for notice in "$tmp"/*.txt; do
            [ -e "$notice" ] || continue
            echo
            echo "----------------------------------------------------------------------"
            echo "Carried by: $(tr '\n' ' ' <"${notice%.txt}.files")"
            echo
            cat "$notice"
        done
    } >"$3"
    grep -q 'Permission is hereby granted' "$3" || die "no MIT notice in the headers under $2"
}

case $platform in
    manylinux-* | windows-*)
        notices "nv-codec-headers $NVCODEC_TAG ($NVCODEC_REPO)" \
            "$work/nv-codec-headers/include" "$stage/LICENSE.nv-codec-headers"
        ;;
esac
if [ "$platform" = windows-x86_64 ]; then
    notices "the AMF headers ($AMF_URL)" "$amf_include" "$stage/LICENSE.AMF"
fi

{
    echo "ffmpeg $FFMPEG_TAG"
    for pair in $MAJORS; do
        echo "${pair%%:*} ${pair#*:}"
    done
} >"$stage/VERSION"

{
    echo "./configure $args"
    for api in $dropped; do
        echo "# dropped: $api, configure found no headers for it"
    done
    for c in $disabled; do
        echo "# disabled by configure: $c"
    done
} >"$stage/CONFIGURE"

tar -czf "$dist/$name.tar.gz" -C "$work/stage" "$name"
echo "packed $dist/$name.tar.gz"
ls -l "$stage"
cat "$stage/VERSION" "$stage/CONFIGURE"
