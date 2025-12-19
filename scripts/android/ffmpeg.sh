HOST_PKG_CONFIG_PATH=$(command -v pkg-config)
if [ -z "${HOST_PKG_CONFIG_PATH}" ]; then
  echo -e "\n(*) pkg-config command not found\n"
  exit 1
fi
LIB_NAME="ffmpeg"
echo -e "----------------------------------------------------------------" 1>>"${BASEDIR}"/build.log 2>&1
echo -e "\nINFO: Building ${LIB_NAME} for ${HOST} with the following environment variables\n" 1>>"${BASEDIR}"/build.log 2>&1
env 1>>"${BASEDIR}"/build.log 2>&1
echo -e "----------------------------------------------------------------\n" 1>>"${BASEDIR}"/build.log 2>&1
echo -e "INFO: System information\n" 1>>"${BASEDIR}"/build.log 2>&1
echo -e "INFO: $(uname -a)\n" 1>>"${BASEDIR}"/build.log 2>&1
echo -e "----------------------------------------------------------------\n" 1>>"${BASEDIR}"/build.log 2>&1
FFMPEG_LIBRARY_PATH="${LIB_INSTALL_BASE}/${LIB_NAME}"
ANDROID_SYSROOT="${ANDROID_NDK_ROOT}"/toolchains/llvm/prebuilt/"${TOOLCHAIN}"/sysroot
# SET PATHS
set_toolchain_paths "${LIB_NAME}"
# SET BUILD FLAGS
HOST=$(get_host)
export CFLAGS=$(get_cflags "${LIB_NAME}")
export CXXFLAGS=$(get_cxxflags "${LIB_NAME}")
export LDFLAGS=$(get_ldflags "${LIB_NAME}")
export PKG_CONFIG_LIBDIR="${INSTALL_PKG_CONFIG_DIR}"
# -----------------------------------------------------------------------------
# CUSTOMIZATION: Ensure 16KB Page Alignment for Android 15
# -----------------------------------------------------------------------------
if [[ "${ARCH}" == "arm64-v8a" || "${ARCH}" == "x86-64" ]]; then
    export LDFLAGS="${LDFLAGS} -Wl,-z,max-page-size=16384"
fi
# -----------------------------------------------------------------------------
cd "${BASEDIR}"/src/"${LIB_NAME}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
# SET BUILD OPTIONS
TARGET_CPU=""
TARGET_ARCH=""
ASM_OPTIONS=""
case ${ARCH} in
arm-v7a)
  TARGET_CPU="armv7-a"
  TARGET_ARCH="armv7-a"
  ASM_OPTIONS=" --disable-neon --enable-asm --enable-inline-asm"
  ;;
arm-v7a-neon)
  TARGET_CPU="armv7-a"
  TARGET_ARCH="armv7-a"
  ASM_OPTIONS=" --enable-neon --enable-asm --enable-inline-asm --build-suffix=_neon"
  ;;
arm64-v8a)
  TARGET_CPU="armv8-a"
  TARGET_ARCH="aarch64"
  ASM_OPTIONS=" --enable-neon --enable-asm --enable-inline-asm"
  ;;
x86)
  TARGET_CPU="i686"
  TARGET_ARCH="i686"
  # asm disabled due to this ticket https://trac.ffmpeg.org/ticket/4928
  ASM_OPTIONS=" --disable-neon --disable-asm --disable-inline-asm"
  ;;
x86-64)
  TARGET_CPU="x86_64"
  TARGET_ARCH="x86_64"
  ASM_OPTIONS=" --disable-neon --enable-asm --enable-inline-asm"
  ;;
esac
CONFIGURE_POSTFIX=""
HIGH_PRIORITY_INCLUDES=""
# -----------------------------------------------------------------------------
# CUSTOMIZATION: Minimal Subtitle-Only Configuration
# -----------------------------------------------------------------------------
# We ignore the standard loop for libraries and define our strict requirements.
# If you want to keep external libraries (like zlib), uncomment specific lines.
# Define minimal components
MINIMAL_FLAGS="
    --disable-everything
    --disable-doc
    --disable-programs
    --disable-avdevice
    --disable-swresample
    --disable-postproc
    --disable-avfilter
    --disable-network
    
    --enable-protocol=file
    --enable-protocol=pipe
    
    --enable-ffmpeg
    --enable-ffprobe
    
    --enable-demuxer=matroska
    --enable-demuxer=mov
    --enable-demuxer=avi
    --enable-demuxer=srt
    --enable-demuxer=webvtt
    --enable-demuxer=ass
    
    --enable-muxer=srt
    --enable-muxer=webvtt
    --enable-muxer=ass
    --enable-muxer=null
    
    --enable-decoder=srt
    --enable-decoder=subrip
    --enable-decoder=webvtt
    --enable-decoder=ass
    --enable-decoder=ssa
    --enable-decoder=text
    --enable-decoder=mov_text
    
    --enable-encoder=srt
    --enable-encoder=subrip
    --enable-encoder=webvtt
    --enable-encoder=ass
    --enable-encoder=ssa
    --enable-encoder=text
    
    --enable-parser=dvdsub
    --enable-parser=dvd_nav
"
# Handle external libraries if strictly needed (e.g., zlib, iconv)
# Checking a few critical ones
for library in {0..61}; do
  if [[ ${ENABLED_LIBRARIES[$library]} -eq 1 ]]; then
    ENABLED_LIBRARY=$(get_library_name ${library})
    
    # Only enable absolutely essential system libs if configured
    case ${ENABLED_LIBRARY} in
    android-zlib)
      CFLAGS+=" $(pkg-config --cflags zlib 2>>"${BASEDIR}"/build.log)"
      LDFLAGS+=" $(pkg-config --libs --static zlib 2>>"${BASEDIR}"/build.log)"
      CONFIGURE_POSTFIX+=" --enable-zlib"
      ;;
    libiconv)
      CFLAGS+=" $(pkg-config --cflags libiconv 2>>"${BASEDIR}"/build.log)"
      LDFLAGS+=" $(pkg-config --libs --static libiconv 2>>"${BASEDIR}"/build.log)"
      CONFIGURE_POSTFIX+=" --enable-iconv"
      HIGH_PRIORITY_INCLUDES+=" $(pkg-config --cflags libiconv 2>>"${BASEDIR}"/build.log)"
      ;;
    esac
  fi
done
# SET ENABLE GPL FLAG WHEN REQUESTED
if [ "$GPL_ENABLED" == "yes" ]; then
  CONFIGURE_POSTFIX+=" --enable-gpl"
fi
export LDFLAGS+=" -L${ANDROID_NDK_ROOT}/platforms/android-${API}/arch-${TOOLCHAIN_ARCH}/usr/lib"
# LINKING WITH ANDROID LTS SUPPORT LIBRARY IS NECESSARY FOR API < 18
if [[ -n ${FFMPEG_KIT_LTS_BUILD} ]] && [[ ${API} -lt 18 ]]; then
  export LDFLAGS+=" -Wl,--whole-archive ${BASEDIR}/android/ffmpeg-kit-android-lib/src/main/cpp/libandroidltssupport.a -Wl,--no-whole-archive"
fi
# ALWAYS BUILD SHARED LIBRARIES
BUILD_LIBRARY_OPTIONS="--disable-static --enable-shared"
# OPTIMIZE FOR SPEED INSTEAD OF SIZE
if [[ -z ${FFMPEG_KIT_OPTIMIZED_FOR_SPEED} ]]; then
  SIZE_OPTIONS="--enable-small"
else
  SIZE_OPTIONS=""
fi
# SET DEBUG OPTIONS
if [[ -z ${FFMPEG_KIT_DEBUG} ]]; then
  # SET LTO FLAGS
  if [[ -z ${NO_LINK_TIME_OPTIMIZATION} ]]; then
    DEBUG_OPTIONS="--disable-debug --enable-lto"
  else
    DEBUG_OPTIONS="--disable-debug --disable-lto"
  fi
else
  DEBUG_OPTIONS="--enable-debug --disable-stripping"
fi
echo -n -e "\n${LIB_NAME}: "
if [[ -z ${NO_WORKSPACE_CLEANUP_ffmpeg} ]]; then
  echo -e "INFO: Cleaning workspace for ${LIB_NAME}\n" 1>>"${BASEDIR}"/build.log 2>&1
  make distclean 2>/dev/null 1>/dev/null
  # WORKAROUND TO MANUALLY DELETE UNCLEANED FILES
  rm -f "${BASEDIR}"/src/"${LIB_NAME}"/libavfilter/opencl/*.o 1>>"${BASEDIR}"/build.log 2>&1
  rm -f "${BASEDIR}"/src/"${LIB_NAME}"/libavcodec/neon/*.o 1>>"${BASEDIR}"/build.log 2>&1
  # DELETE SHARED FRAMEWORK WORKAROUNDS
  git checkout "${BASEDIR}/src/ffmpeg/ffbuild" 1>>"${BASEDIR}"/build.log 2>&1
fi
# UPDATE BUILD FLAGS
export CFLAGS="${HIGH_PRIORITY_INCLUDES} ${CFLAGS}"
# USE HIGHER LIMITS FOR FFMPEG LINKING
ulimit -n 2048 1>>"${BASEDIR}"/build.log 2>&1
########################### CUSTOMIZATIONS #######################
cd "${BASEDIR}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
git checkout android/ffmpeg-kit-android-lib/src/main/cpp/ffmpegkit.c 1>>"${BASEDIR}"/build.log 2>&1
cd "${BASEDIR}"/src/"${LIB_NAME}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
git checkout libavformat/file.c 1>>"${BASEDIR}"/build.log 2>&1
git checkout libavformat/protocols.c 1>>"${BASEDIR}"/build.log 2>&1
git checkout libavutil 1>>"${BASEDIR}"/build.log 2>&1
# 1. Use thread local log levels
${SED_INLINE} 's/static int av_log_level/__thread int av_log_level/g' "${BASEDIR}"/src/"${LIB_NAME}"/libavutil/log.c 1>>"${BASEDIR}"/build.log 2>&1 || return 1
# 2. Enable ffmpeg-kit protocols
if [[ ${NO_FFMPEG_KIT_PROTOCOLS} == "1" ]]; then
  ${SED_INLINE} "s| av_set_saf|//av_set_saf|g" "${BASEDIR}"/android/ffmpeg-kit-android-lib/src/main/cpp/ffmpegkit.c 1>>"${BASEDIR}"/build.log 2>&1
  echo -e "\nINFO: Disabled custom ffmpeg-kit protocols\n" 1>>"${BASEDIR}"/build.log 2>&1
else
  cat ../../tools/protocols/libavformat_file.c >> libavformat/file.c
  cat ../../tools/protocols/libavutil_file.h >> libavutil/file.h
  cat ../../tools/protocols/libavutil_file.c >> libavutil/file.c
  awk '{gsub(/ff_file_protocol;/,"ff_file_protocol;\nextern const URLProtocol ff_saf_protocol;")}1' libavformat/protocols.c > libavformat/protocols.c.tmp
  cat libavformat/protocols.c.tmp > libavformat/protocols.c
  echo -e "\nINFO: Enabled custom ffmpeg-kit protocols\n" 1>>"${BASEDIR}"/build.log 2>&1
fi
###################################################################
./configure \
  --cross-prefix="${HOST}-" \
  --sysroot="${ANDROID_SYSROOT}" \
  --prefix="${FFMPEG_LIBRARY_PATH}" \
  --pkg-config="${HOST_PKG_CONFIG_PATH}" \
  --enable-version3 \
  --arch="${TARGET_ARCH}" \
  --cpu="${TARGET_CPU}" \
  --target-os=android \
  ${ASM_OPTIONS} \
  --ar="${AR}" \
  --cc="${CC}" \
  --cxx="${CXX}" \
  --ranlib="${RANLIB}" \
  --strip="${STRIP}" \
  --nm="${NM}" \
  --extra-libs="$(pkg-config --libs --static cpu-features)" \
  --disable-autodetect \
  --enable-cross-compile \
  --enable-pic \
  --enable-jni \
  --enable-optimizations \
  --enable-swscale \
  ${BUILD_LIBRARY_OPTIONS} \
  --enable-pthreads \
  --enable-v4l2-m2m \
  --disable-outdev=fbdev \
  --disable-indev=fbdev \
  ${SIZE_OPTIONS} \
  --disable-xmm-clobber-test \
  ${DEBUG_OPTIONS} \
  --disable-neon-clobber-test \
  --disable-htmlpages \
  --disable-manpages \
  --disable-podpages \
  --disable-txtpages \
  --disable-sndio \
  --disable-schannel \
  --disable-securetransport \
  --disable-xlib \
  --disable-cuda \
  --disable-cuvid \
  --disable-nvenc \
  --disable-vaapi \
  --disable-vdpau \
  --disable-videotoolbox \
  --disable-audiotoolbox \
  --disable-appkit \
  --disable-alsa \
  --disable-cuda \
  --disable-cuvid \
  --disable-nvenc \
  --disable-vaapi \
  --disable-vdpau \
  ${MINIMAL_FLAGS} \
  ${CONFIGURE_POSTFIX} 1>>"${BASEDIR}"/build.log 2>&1
if [[ $? -ne 0 ]]; then
  echo -e "failed\n\nSee build.log for details\n"
  exit 1
fi
if [[ -z ${NO_OUTPUT_REDIRECTION} ]]; then
  make -j$(get_cpu_count) 1>>"${BASEDIR}"/build.log 2>&1
  if [[ $? -ne 0 ]]; then
    echo -e "failed\n\nSee build.log for details\n"
    exit 1
  fi
else
  echo -e "started\n"
  make -j$(get_cpu_count)
  if [[ $? -ne 0 ]]; then
    echo -n -e "\n${LIB_NAME}: failed\n\nSee build.log for details\n"
    exit 1
  else
    echo -n -e "\n${LIB_NAME}: "
  fi
fi
# DELETE THE PREVIOUS BUILD OF THE LIBRARY BEFORE INSTALLING
if [ -d "${FFMPEG_LIBRARY_PATH}" ]; then
  rm -rf "${FFMPEG_LIBRARY_PATH}" 1>>"${BASEDIR}"/build.log 2>&1 || return 1
fi
make install 1>>"${BASEDIR}"/build.log 2>&1
if [[ $? -ne 0 ]]; then
  echo -e "failed\n\nSee build.log for details\n"
  exit 1
fi
# MANUALLY ADD REQUIRED HEADERS
mkdir -p "${FFMPEG_LIBRARY_PATH}"/include/libavutil/x86 1>>"${BASEDIR}"/build.log 2>&1
mkdir -p "${FFMPEG_LIBRARY_PATH}"/include/libavutil/arm 1>>"${BASEDIR}"/build.log 2>&1
mkdir -p "${FFMPEG_LIBRARY_PATH}"/include/libavutil/aarch64 1>>"${BASEDIR}"/build.log 2>&1
mkdir -p "${FFMPEG_LIBRARY_PATH}"/include/libavcodec/x86 1>>"${BASEDIR}"/build.log 2>&1
mkdir -p "${FFMPEG_LIBRARY_PATH}"/include/libavcodec/arm 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/config.h "${FFMPEG_LIBRARY_PATH}"/include/config.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavcodec/mathops.h "${FFMPEG_LIBRARY_PATH}"/include/libavcodec/mathops.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavcodec/x86/mathops.h "${FFMPEG_LIBRARY_PATH}"/include/libavcodec/x86/mathops.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavcodec/arm/mathops.h "${FFMPEG_LIBRARY_PATH}"/include/libavcodec/arm/mathops.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavformat/network.h "${FFMPEG_LIBRARY_PATH}"/include/libavformat/network.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavformat/os_support.h "${FFMPEG_LIBRARY_PATH}"/include/libavformat/os_support.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavformat/url.h "${FFMPEG_LIBRARY_PATH}"/include/libavformat/url.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/attributes_internal.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/attributes_internal.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/bprint.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/bprint.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/getenv_utf8.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/getenv_utf8.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/internal.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/internal.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/libm.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/libm.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/reverse.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/reverse.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/thread.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/thread.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/timer.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/timer.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/x86/asm.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/x86/asm.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/x86/timer.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/x86/timer.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/arm/timer.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/arm/timer.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/aarch64/timer.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/aarch64/timer.h 1>>"${BASEDIR}"/build.log 2>&1
overwrite_file "${BASEDIR}"/src/ffmpeg/libavutil/x86/emms.h "${FFMPEG_LIBRARY_PATH}"/include/libavutil/x86/emms.h 1>>"${BASEDIR}"/build.log 2>&1
if [ $? -eq 0 ]; then
  echo "ok"
else
  echo -e "failed\n\nSee build.log for details\n"
  exit 1
fi
