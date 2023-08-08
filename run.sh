#!/bin/bash
# vim: ft=sh
# Copyright (c) KenHV
git clone https://github.com/KenHV/gcc-arm64.git $HOME/projects/gcc/gcc-arm64
git clone https://github.com/SuS-Devices/kensur_kernel_liber $HOME/projects/liber/kernel
git clone https://github.com/menorziin/AnyKernel3 $HOME/projects/liber/kernel/ak3
# Build kernel in tmpfs
TMPFS=1

# Build modules
MODULES=0

# Compiler (clang/gcc)
COMPILER=gcc
DEVICE=liber

# Colors
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)

export RED
export GREEN
export YELLOW
export BLUE
export MAGENTA
export CYAN
export RESET

# handle SIGINT
function ctrl_c() {
    header "Cancelled build" "$YELLOW"
    [[ -n "$CAPTION" ]] && echo "$CAPTION"
    exit 0
}
trap ctrl_c INT


function echo() {
    command echo -e "$@"
}


function header() {
    if [[ -n ${2} ]]; then
        COLOR=${2}
    else
        COLOR=${BLUE}
    fi
    echo "${COLOR}"
    # shellcheck disable=SC2034
    echo "====$(for i in $(seq ${#1}); do echo "=\c"; done)===="
    echo "=== ${1} ==="
    # shellcheck disable=SC2034
    echo "====$(for i in $(seq ${#1}); do echo "=\c"; done)===="
    echo "${RESET}"
}


function exports() {
    DEFCONFIG="$DEVICE-perf_defconfig"

    BASE=$HOME/projects/$DEVICE

    AK3="$BASE"/ak3
    JOBS=-j6
    KERN_DIR="$BASE"/kernel
    LOG="$BASE"/log-kernel-build.txt

    if [ "$TMPFS" = "0" ]; then
        OUT="$KERN_DIR"/out
    else
        OUT=/tmp/kernel
    fi

    DTB="$OUT"/arch/arm64/boot/dtb.img
    DTBO="$OUT"/arch/arm64/boot/dtbo.img

    if [[ "$DEVICE" = "liber" ]]; then
        KERN_IMG="$OUT"/arch/arm64/boot/Image.gz
    elif [[ "$DEVICE" = "vince" ]]; then
        KERN_IMG="$OUT"/arch/arm64/boot/Image.gz-dtb
    fi

    # GCC
    if [ "$COMPILER" = "gcc" ]; then
        GCC_PATH="$HOME/projects/gcc"
        MAKE=(
            #CROSS_COMPILE_ARM32=arm-eabi- \
            #CROSS_COMPILE=aarch64-elf- \
            #AR=aarch64-elf-ar \
            #OBJDUMP=aarch64-elf-objdump \
            #STRIP=aarch64-elf-strip \
            #NM=aarch64-elf-nm \
            #OBJCOPY=aarch64-elf-objcopy \
            CROSS_COMPILE=aarch64-elf- \
            CROSS_COMPILE_ARM32=arm-eabi- \
            O="$OUT"
        )
        export PATH="$GCC_PATH/gcc-arm64/bin:/$GCC_PATH/gcc-arm/bin:$PATH"
        KBUILD_COMPILER_STRING=$("$GCC_PATH"/gcc-arm64/bin/aarch64-elf-gcc --version | head -n 1)
        export KBUILD_COMPILER_STRING
    fi

    if [ "$COMPILER" = "clang" ]; then
        MAKE=(
            CROSS_COMPILE=aarch64-linux-gnu- \
            CROSS_COMPILE_ARM32=arm-none-eabi- \
            CC=clang \
            AR=llvm-ar \
            OBJDUMP=llvm-objdump \
            STRIP=llvm-strip \
            NM=llvm-nm \
            OBJCOPY=llvm-objcopy \
            LD=ld.lld \
            O="$OUT"
        )
        export PATH="$BASE/clang/bin:$PATH"
        KBUILD_COMPILER_STRING=$("$BASE"/clang/bin/clang --version | head -n 1 | \
            perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')
        export KBUILD_COMPILER_STRING
    fi

    export ARCH=arm64; export SUBARCH=arm64
    export KBUILD_BUILD_HOST="Kensur"; export KBUILD_BUILD_USER="IMPOSTER"
    export KBUILD_JOBS=$JOBS
}


function setup() {
    header "Setting up"
    cd "$KERN_DIR" || exit 1

    echo "Compiler: $KBUILD_COMPILER_STRING"

    COMMIT=$(git log --pretty=format:"%s" -1)
    COMMIT_SHA=$(git rev-parse --short HEAD)
    KERN_VER=$(make kernelversion -s)

    CAPTION="${RED}HEAD:${RESET} $COMMIT_SHA: $COMMIT"

    [[ ! -d out ]] && mkdir out
    [[ -f "$KERN_IMG" ]] && rm "$KERN_IMG"

    while [[ ! $# -eq 0 ]]
    do
        case "$1" in
            --clean | -c)
                [[ $FP == "FPC" ]] || make mrproper "$JOBS" "${MAKE[@]}"
                ;;
            --regen | -r)
                make $DEFCONFIG --no-print-directory
                make savedefconfig --no-print-directory
                cp out/defconfig arch/arm64/configs/$DEFCONFIG
                git add arch/arm64/configs/$DEFCONFIG
                git commit -m "defconfig: Regenerate

This is an auto-generated commit."
                ;;
        esac
        shift
    done
    make "${MAKE[@]}" $DEFCONFIG
}


function build() {
    header "Starting build..."
    BUILD_START=$(date +"%s")
    make "$JOBS" "${MAKE[@]}" |& tee "$LOG"

    if [ "$MODULES" = "1" ]; then
        make "$JOBS" "${MAKE[@]}" modules_prepare
        make "$JOBS" "${MAKE[@]}" modules INSTALL_MOD_PATH="$OUT"/modules
        make "$JOBS" "${MAKE[@]}" modules_install INSTALL_MOD_PATH="$OUT"/modules
    fi

    BUILD_END=$(date +"%s")
    DIFF=$((BUILD_END - BUILD_START))

    CAPTION="${RED}HEAD:${RESET} $COMMIT_SHA: $COMMIT
${RED}Time taken:${RESET} $((DIFF / 60))m $((DIFF % 60))s"

    if ! [[ -a "$KERN_IMG" ]]; then
        header "Build failed." "$RED"
        echo "$CAPTION"
        exit 1
    fi

    IMG_SIZE=$(du -BK "$KERN_IMG" | awk '{ print $1 }')

    CAPTION="${RED}HEAD:${RESET} $COMMIT_SHA: $COMMIT
${RED}Time taken:${RESET} $((DIFF / 60))m $((DIFF % 60))s
${RED}Image size:${RESET} $IMG_SIZE"

}


function genzip() {
    header "Build successful!" "$BLUE"
    cd "$AK3" || exit 1
    git reset --hard HEAD
    git clean -fd
    mv "$DTB" "$AK3/dtb"
    mv "$DTBO" "$AK3"
    mv "$KERN_IMG" "$AK3"
    if [ "$MODULES" = "1" ]; then
        sed -i 's/do\.modules=0/do.modules=1/' anykernel.sh
        mkdir -p modules/vendor/lib/modules
        find "$OUT"/modules -type f -iname '*.ko' -exec cp {} modules/vendor/lib/modules/ \;
    fi

    if [[ -z ${FP+x} ]]; then
        ZIP_NAME=Kensur-$DEVICE-$KERN_VER-$COMMIT_SHA.zip
    else
        ZIP_NAME=Kensur-$DEVICE-$FP-$KERN_VER-$COMMIT_SHA.zip
    fi

    zip -r9 "$ZIP_NAME" ./* -x .git README.md ./*placeholder
    ZIP=$(echo "$AK3"/*.zip)
}


function copyzip() {
    if adb push "$ZIP" /sdcard/Kernel &> /dev/null; then
        header "Copied ZIP to device." "$BLUE"
        return 0
    fi

    header "Device isn't connected, pushing to TG." "$YELLOW"
    return 1
}


function uploadzip() {
    [[ -z ${FP+x} ]] && CAPTION_MD="*HEAD:* \`$COMMIT_SHA\`: \`$COMMIT\`
*Time taken:* $((DIFF / 60))m $((DIFF % 60))s
*Image size:* $IMG_SIZE"

    curl -sSfo /dev/null -F document=@"$ZIP" \
        "https://api.telegram.org/bot$TG_BOT_TOKEN/sendDocument" \
        -F chat_id="$TG_CHAT_ID" \
        -F parse_mode=markdownv2 \
        -F caption="$CAPTION_MD" \
        && header "Uploaded build to Telegram."
}

# TODO: Cleanup

exports
setup "$@"

if [[ $@ =~ "--release" ]]; then
    sed -i '/qcom,force-warm-reboot;/d' "$KERN_DIR"/arch/arm64/boot/dts/qcom/sdmmagpie.dtsi

    # Make build for goodix
    FP=Goodix
    build
    genzip
    uploadzip

    # Make build for fpc
    cd "$KERN_DIR" || exit 1
    FP=FPC
    echo CONFIG_FINGERPRINT_GOODIX_FOD_MMI=n >> "$OUT"/.config
    echo CONFIG_FINGERPRINT_FPC_TEE_MMI=y >> "$OUT"/.config
    echo CONFIG_INPUT_MISC_FPC1020_SAVE_TO_CLASS_DEVICE=y >> "$OUT"/.config
    build
    genzip
    uploadzip
else
    build
    genzip
    copyzip || uploadzip
fi

echo "$CAPTION"
exit 0
