# ffrwd-av

LGPL-only shared builds of libavutil, libswresample, libavcodec,
libswscale and libavfilter for the ffrwd sidecar wheel (`ffrwd-wasm`).
The sidecar loads them at run time, and each platform's wheel carries its
archive's libraries beside the sidecar binary, so `pip install ffrwd`
remains the whole install.

Every build is FFmpeg tag `n9.0.1`:

| library       | major | Linux               | macOS                  | Windows            |
|---------------|-------|---------------------|------------------------|--------------------|
| libavutil     | 61    | `libavutil.so.61`   | `libavutil.61.dylib`   | `avutil-61.dll`    |
| libswresample | 7     | `libswresample.so.7`| `libswresample.7.dylib`| `swresample-7.dll` |
| libavcodec    | 63    | `libavcodec.so.63`  | `libavcodec.63.dylib`  | `avcodec-63.dll`   |
| libswscale    | 10    | `libswscale.so.10`  | `libswscale.10.dylib`  | `swscale-10.dll`   |
| libavfilter   | 12    | `libavfilter.so.12` | `libavfilter.12.dylib` | `avfilter-12.dll`  |

No libavformat or libavdevice is built. Nothing is configured with
`--enable-gpl` or `--enable-nonfree`, and no external encoder library is
linked.

## Platforms

The platform names are the sidecar wheel's targets, and each is built
where the wheel's platform tag says it runs:

| platform            | built on                                                   |
|---------------------|------------------------------------------------------------|
| `manylinux-x86_64`  | `quay.io/pypa/manylinux_2_28_x86_64`                       |
| `manylinux-aarch64` | `quay.io/pypa/manylinux_2_28_aarch64`, under QEMU          |
| `musllinux-x86_64`  | `quay.io/pypa/musllinux_1_2_x86_64`                        |
| `musllinux-aarch64` | `quay.io/pypa/musllinux_1_2_aarch64`, under QEMU           |
| `macos-aarch64`     | `macos-latest`                                             |
| `windows-x86_64`    | `windows-latest`, MSYS2 UCRT64 with gcc                    |
| `windows-aarch64`   | `ubuntu-latest`, cross-compiled with llvm-mingw 20260616   |

The two aarch64 Linux builds run their images under QEMU
(`docker/setup-qemu-action`) rather than with a cross toolchain. The
emulated image is the same one the x86_64 build uses, so the build script
runs unchanged, the image's own `dnf` supplies the vulkan headers, and
the glibc the libraries are linked against is the one the wheel's
manylinux tag promises. A cross toolchain would need its own glibc 2.28
sysroot to give the same guarantee. The cost is time: these two jobs take
several times longer than the others. If this repository is public, GitHub's native `ubuntu-24.04-arm`
runners would remove that cost and change nothing else.

The Windows DLLs are built with mingw-w64 against the UCRT, the C runtime
the sidecar's MSVC build also uses. A mingw-built DLL loads into an MSVC
process; FFmpeg's API frees what it allocates, so no allocation crosses
the two.

## Sources

Every source is pinned in `scripts/build.sh`:

- FFmpeg `n9.0.1`, `https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz`,
  sha256 `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635`
  (12036420 bytes). The same digest is published by Homebrew's and
  MacPorts' ffmpeg 9.0.1 packages.
- nv-codec-headers (MIT) `n12.1.14.0`, cloned at the tag and checked
  against commit `1889e62e2d35ff7aa9baca2bceb14f053785e6f1`, on the Linux
  glibc and Windows builds. 12.1.14.0 is the oldest release FFmpeg 9.0's
  configure prefers, and an older header release keeps the NVIDIA driver
  minimum low: 530.41.03 on Linux, 531.61 on Windows.
- AMF headers (MIT) `v1.5.2`, the release's `AMF-headers-v1.5.2.tar.gz`,
  sha256 `d3c12eb324edf05e214608b6a395a51dd95770ed9d45520185d6c3a206811c99`,
  on Windows x86_64 only. 1.5.2 is the oldest FFmpeg 9.0 accepts; FFmpeg
  initialises AMF with the headers' version, so newer headers can raise
  the AMD driver minimum.
- llvm-mingw `20260616`, `llvm-mingw-20260616-ucrt-ubuntu-22.04-x86_64.tar.xz`,
  sha256 `534b92e067b22a6b4441f48ae9240a3341b17825d04d577eab0cf85c44b4deda`,
  for windows-aarch64.
- The vulkan headers come from the manylinux image's package manager
  (`vulkan-headers`).

The script also checks the five majors in the FFmpeg source against the
table above before building.

## Configure lines

All platforms share this start, with `<build>` the platform's build
directory:

```sh
./configure --prefix=<build>/prefix \
  --disable-everything --disable-programs --disable-doc \
  --disable-static --enable-shared \
  --disable-avformat --enable-avfilter --disable-avdevice \
  --enable-swscale --enable-swresample \
  --disable-network --disable-autodetect --enable-pic \
  --enable-decoder=h264,hevc,av1,vp9,mpeg2video,prores,mjpeg,ffv1,mpeg4 \
  --enable-parser=h264,hevc,av1,vp9,mpegvideo,mjpeg,mpeg4video \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --enable-encoder=ffv1,mpeg4,mpeg2video,mjpeg \
  --enable-filter=buffer,buffersink,format,hwupload,hwdownload,null \
```

followed by each platform's own flags.

**manylinux-x86_64, manylinux-aarch64**

```sh
  --enable-ffnvcodec --enable-cuda --enable-cuda-llvm --enable-nvdec --enable-nvenc \
  --enable-vulkan \
  --enable-hwaccel=h264_nvdec,hevc_nvdec,av1_nvdec,vp9_nvdec,mpeg2_nvdec,h264_vulkan,hevc_vulkan,av1_vulkan \
  --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc \
  --enable-filter=scale_cuda,overlay_cuda,pad_cuda,transpose_cuda,yadif_cuda,bwdif_cuda,chromakey_cuda,colorspace_cuda,scale_vulkan,overlay_vulkan,blend_vulkan,transpose_vulkan,flip_vulkan,hflip_vulkan,vflip_vulkan,bwdif_vulkan,gblur_vulkan,avgblur_vulkan,nlmeans_vulkan,xfade_vulkan,chromaber_vulkan \
  --enable-pthreads \
  --extra-ldflags="-Wl,-rpath,'\\\$\\\$\\\$\\\$ORIGIN'"
```

**musllinux-x86_64, musllinux-aarch64** (software codecs only)

```sh
  --enable-pthreads \
  --extra-ldflags="-Wl,-rpath,'\\\$\\\$\\\$\\\$ORIGIN'"
```

**macos-aarch64**

```sh
  --enable-videotoolbox \
  --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox \
  --enable-encoder=h264_videotoolbox,hevc_videotoolbox,prores_videotoolbox \
  --enable-pthreads --install-name-dir=@rpath \
  --extra-cflags=-mmacosx-version-min=11.0 \
  --extra-ldflags=-mmacosx-version-min=11.0 \
  --extra-ldflags=-Wl,-rpath,@loader_path
```

**windows-x86_64**

```sh
  --enable-ffnvcodec --enable-cuda --enable-nvdec --enable-nvenc \
  --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation \
  --enable-amf \
  --enable-hwaccel=h264_d3d11va,hevc_d3d11va,av1_d3d11va,vp9_d3d11va,mpeg2_d3d11va,h264_d3d12va,hevc_d3d12va,av1_d3d12va,vp9_d3d12va,mpeg2_d3d12va,h264_dxva2,hevc_dxva2,h264_nvdec,hevc_nvdec,av1_nvdec,vp9_nvdec,mpeg2_nvdec \
  --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc,h264_d3d12va,hevc_d3d12va,h264_amf,hevc_amf,av1_amf,h264_mf,hevc_mf \
  --enable-filter=scale_d3d12,deinterlace_d3d12 \
  --enable-w32threads --extra-ldflags=-static
```

**windows-aarch64**

```sh
  --enable-ffnvcodec --enable-cuda --enable-nvdec --enable-nvenc \
  --enable-d3d11va --enable-d3d12va --enable-dxva2 --enable-mediafoundation \
  --enable-hwaccel=h264_d3d11va,hevc_d3d11va,av1_d3d11va,vp9_d3d11va,mpeg2_d3d11va,h264_d3d12va,hevc_d3d12va,av1_d3d12va,vp9_d3d12va,mpeg2_d3d12va,h264_dxva2,hevc_dxva2,h264_nvdec,hevc_nvdec,av1_nvdec,vp9_nvdec,mpeg2_nvdec \
  --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc,h264_d3d12va,hevc_d3d12va,h264_mf,hevc_mf \
  --enable-filter=scale_d3d12,deinterlace_d3d12 \
  --enable-w32threads --extra-ldflags=-static \
  --enable-cross-compile --arch=aarch64 --target-os=mingw32 \
  --cross-prefix=aarch64-w64-mingw32- --cc=aarch64-w64-mingw32-clang \
  --pkg-config=pkg-config
```

The exact line each build ran is the `CONFIGURE` file in its archive.

### Flags beyond the component lists

- `--disable-postproc` is not passed. libpostproc left FFmpeg in 8.0, and
  9.0's configure rejects the option as unknown.
- `--disable-autodetect` also turns off the threading library, so each
  platform enables its own: `--enable-pthreads`, or `--enable-w32threads`
  on Windows. Without it every decoder is single-threaded and vulkan
  cannot be enabled.
- `--enable-cuda` builds libavutil's CUDA device context, which nvdec and
  nvenc work through. It is autodetected, so `--disable-autodetect`
  leaves it off unless named. It needs no CUDA toolkit; the driver is
  loaded at run time.
- `--enable-cuda-llvm` compiles the `_cuda` filters' kernels to PTX with
  clang's NVPTX target, from the image's `clang` package. The PTX is
  embedded in libavfilter and the driver compiles it at run time, so no
  CUDA toolkit is involved. `--enable-cuda-nvcc`, the alternative, is
  non-free and is not used.
- The `_vulkan` filters' shaders are compiled to SPIR-V at build time by
  a GLSL compiler program configure finds on the path (`glslc`,
  `glslang` or `glslangValidator`; the image's `glslang` package) and
  embedded in libavfilter. FFmpeg 9.0 has no run-time shader compiler
  option for them, so the archive carries nothing beyond the five
  libraries for these filters.
- `$ORIGIN` is expanded three times before the linker sees it: once by
  configure's `eval`, and twice by make, because the shared-library link
  rule in `ffbuild/library.mak` is a `$(eval)` template that expands
  `LDFLAGS` when it is evaluated and again when the recipe runs. So the
  argument configure receives is `-Wl,-rpath,'\$\$\$\$ORIGIN'`,
  `config.mak` holds `'$$$$ORIGIN'`, and the single quotes keep the shell
  from expanding the `$ORIGIN` make leaves. The build checks each
  library's RUNPATH is exactly `$ORIGIN`.
- macOS: `--install-name-dir=@rpath` gives each library the install name
  `@rpath/libavutil.61.dylib` (and so on), so its siblings are found
  through its `@loader_path` rpath rather than at the build machine's
  prefix. The minimum macOS is 11.0, the same as the wheel's.
- Windows: `-static` links the toolchain's own runtime (libgcc and
  libwinpthread, or llvm-mingw's libunwind) into each DLL, so nothing but
  system DLLs and the siblings is imported. The build checks each DLL's
  import table.

### Hardware support per platform

- Linux glibc: NVDEC and NVENC through nv-codec-headers, and Vulkan
  decode. NVIDIA's driver and the Vulkan loader are opened at run time,
  so the libraries load on a machine with neither. VA-API is not built:
  libavutil would link `libva.so.2` and `libva-drm.so.2` at load time, and
  on a machine without libva it would not load at all, which a wheel
  cannot rule out.
- Linux musl: software codecs only, no hardware APIs.
- macOS: VideoToolbox decode and encode.
- Windows: D3D11VA, D3D12VA, DXVA2, NVDEC, NVENC, Media Foundation
  encoders, and AMF on x86_64. All of these open their system or driver
  DLLs at run time; none is imported.

### Filters per platform

libavfilter carries `buffer`, `buffersink`, `format`, `hwupload`,
`hwdownload` and `null` on every platform: the two ends of a graph,
format negotiation, and the moves between host and device memory. No
other software filter is built; ffmpeg runs those. The hardware filters:

- Linux glibc: `scale_cuda`, `overlay_cuda`, `pad_cuda`,
  `transpose_cuda`, `yadif_cuda`, `bwdif_cuda`, `chromakey_cuda` and
  `colorspace_cuda`, when clang can target NVPTX; `scale_vulkan`,
  `overlay_vulkan`, `blend_vulkan`, `transpose_vulkan`, `flip_vulkan`,
  `hflip_vulkan`, `vflip_vulkan`, `bwdif_vulkan`, `gblur_vulkan`,
  `avgblur_vulkan`, `nlmeans_vulkan`, `xfade_vulkan` and
  `chromaber_vulkan`, when Vulkan is built and a GLSL compiler is found.
  `libplacebo` is not built: it is a library of its own, with a run-time
  shader compiler, that the archive would have to carry.
- Windows: `scale_d3d12` and `deinterlace_d3d12`, which need
  `ID3D12VideoProcessor` in the toolchain's `d3d12video.h`.
- Linux musl and macOS: none. macOS's `scale_vt` and `transpose_vt` are
  not built.

When configure cannot find clang with the NVPTX target, the build drops
`cuda_llvm` and the `_cuda` filters the way it drops Vulkan, keeps NVDEC
and NVENC, and records the drop in `CONFIGURE`. A `_vulkan` filter
without a GLSL compiler, or a `_d3d12` one without the type, is turned
off by configure and recorded as disabled. A missing software filter
fails the build.

libavfilter is checked like the others: on Linux it may need only its
siblings (libavutil and libswscale) and the C library, with a RUNPATH of
`$ORIGIN`; on Windows only system DLLs and its siblings. The hardware
filters reach CUDA, Vulkan and D3D12 through libavutil's device
contexts, which open the driver at run time, so libavfilter imports none
of them.

On manylinux the vulkan headers come from the image's package manager.
When configure cannot find them, or finds them older than FFmpeg 9.0
requires, the build drops Vulkan (`--enable-vulkan` and every hwaccel
named after it, and every `_vulkan` filter), warns, and records the drop
in `CONFIGURE`, rather than failing. A hardware hwaccel, encoder or filter
that configure turns off for a missing type in otherwise present headers
is warned and recorded the same way; a software component missing fails
the build.

manylinux_2_28's AlmaLinux 8 packages carry `vulkan-headers` 1.3.283,
above the 1.3.277 FFmpeg 9.0 requires, so Vulkan is expected to build.

### AV1 decoding

libavcodec's native `av1` decoder decodes only through a hwaccel. Without
NVDEC, Vulkan, D3D11VA or D3D12VA hardware AV1 support, these
libraries do not decode AV1 at all: a software AV1 decoder needs libdav1d,
which is not in this build. On musl and macOS (no AV1 hwaccel is enabled
there) AV1 never decodes.

## Archives

Each archive is `ffrwd-av-<tag>-<platform>.tar.gz` and holds one
directory of the same name containing:

- the five shared libraries, under the file names in the table above and
  nothing else (no unversioned names, no import libraries, no headers);
- `COPYING.LGPLv2.1`, the licence text from the FFmpeg tree;
- `LICENSE.nv-codec-headers`, on the manylinux and Windows platforms,
  and `LICENSE.AMF`, on windows-x86_64: the MIT notices of the headers
  whose code is compiled into the libraries (see Licence);
- `VERSION`: the FFmpeg tag on its first line, then one line per library
  with its major;
- `CONFIGURE`: the exact configure line, followed by a `#` line for each
  API dropped or component configure disabled.

## Licence

The libraries are FFmpeg under the LGPL 2.1 or later. They are shipped as
shared libraries that the sidecar loads dynamically, and each archive
carries the LGPL text beside them in `COPYING.LGPLv2.1`; the sidecar
wheel ships that file in the same directory as the libraries. That, with
the source tag and configure line recorded here and in each archive, is
the LGPL obligation.

nv-codec-headers and the AMF headers are MIT-licensed, and their code
(NVIDIA's and AMD's runtime loaders) is compiled into the libraries, so
their notices travel with them. Neither source ships a separate licence
file: nv-codec-headers has none, and the AMF notice is at the top of each
header. The build collects each distinct notice from the leading comment
of every header it compiled against and writes them, with the headers
that carry each one, to `LICENSE.nv-codec-headers` and `LICENSE.AMF`.
The build fails if it finds no MIT notice in either set of headers.

## Cutting a release

1. Change the pins in `scripts/build.sh` if needed, commit, and push.
2. Tag the commit `vN` (annotated) and push the tag.
3. `.github/workflows/build.yml` builds every platform. When all seven
   succeed, it creates the GitHub release for the tag with the seven
   archives and `pins.json` attached. If any platform fails, nothing is
   released.

A `workflow_dispatch` run builds every platform and uploads the archives
and `pins.json` as workflow artifacts without releasing; its archive names
carry `dev-<commit>` instead of a tag.

`pins.json` maps each platform to its archive:

```json
{
  "manylinux-x86_64": {
    "url": "https://github.com/imbcmdth/ffrwd-av/releases/download/vN/ffrwd-av-vN-manylinux-x86_64.tar.gz",
    "sha256": "...",
    "bytes": 12345678
  }
}
```

`scripts/pins.py <dir> <url prefix>` writes it from a directory of
archives; it fails unless all seven platforms are present, or with
`--partial` maps those that are.

## How ffrwd-cli uses a release

ffrwd-cli pins a release in `sidecar/ffrwd-wasm/av-pins.json`:

```json
{
  "ffmpeg": "n9.0.1",
  "majors": {"avutil": 61, "swresample": 7, "avcodec": 63, "swscale": 10, "avfilter": 12},
  "platforms": { ... the contents of this release's pins.json ... }
}
```

Its release workflow runs `sidecar/ffrwd-wasm/fetch_av.py` before each
wheel build. The script picks the platform for the wheel's target,
downloads the archive, checks its sha256 and size against the pin, and
places the libraries, the licence and notice files, `VERSION` and
`CONFIGURE` in
`sidecar/ffrwd-wasm/ffrwd_wasm_av/`, which the wheel ships as
`site-packages/ffrwd_wasm_av/`. A platform with no pin builds a wheel
without codecs.

The release asset URLs must be downloadable without credentials for that
fetch to work.
