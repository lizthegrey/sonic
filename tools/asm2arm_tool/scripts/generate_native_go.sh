#!/bin/bash

set -e

# 清理选项
CLEAN="false"

# 解析命令行参数
while getopts "c" opt; do
  case $opt in
    c)
      CLEAN="true"
      ;;
    *)
      echo "Usage: $0 [-c]"
      echo "  -c: Clean generated files (*.o, *.elf, *.log)"
      exit 1
      ;;
  esac
done

# 获取脚本所在目录的绝对路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cpu_detect.sh"
check_build_host

TOOL_DIR="$(dirname "${SCRIPT_DIR}")"   # asm2arm_tool
PROJECT_DIR="$(dirname $(dirname "${TOOL_DIR}"))"   # sonic

BUILD_DIR="${TOOL_DIR}/build"
TOOL_PATH="${BUILD_DIR}/asm2arm_tool"
LLVM_INSTALL_DIR="${BUILD_DIR}/llvm-install"
CLANG_PATH="${LLVM_INSTALL_DIR}/bin/clang"

SRC_DIR="${PROJECT_DIR}/native"
TMPL_DIR="${PROJECT_DIR}/internal/native"
OUTPUT_DIR="${TOOL_DIR}/output"

# 清理函数
function clean_files() {
  echo ">>> Cleaning generated files..."

  # 清理 neon 目录下的 .o 和 .log 文件
  find "${OUTPUT_DIR}/neon" -name "*.o" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/neon" -name "*.log" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/neon" -name "*.elf" -type f -delete 2>/dev/null || true

  # 清理 sve_linkname 目录下的 .o 和 .log 文件
  find "${OUTPUT_DIR}/sve_linkname" -name "*.o" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/sve_linkname" -name "*.log" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/sve_linkname" -name "*.elf" -type f -delete 2>/dev/null || true

  # 清理 sve_wrapgoc 目录下的 .o 和 .log 文件
  find "${OUTPUT_DIR}/sve_wrapgoc" -name "*.o" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/sve_wrapgoc" -name "*.log" -type f -delete 2>/dev/null || true
  find "${OUTPUT_DIR}/sve_wrapgoc" -name "*.elf" -type f -delete 2>/dev/null || true

  echo ">>> Clean completed!"
}

# 创建输出目录
mkdir -p "${OUTPUT_DIR}/neon"
mkdir -p "${OUTPUT_DIR}/sve_linkname"
mkdir -p "${OUTPUT_DIR}/sve_wrapgoc"
mkdir -p "${OUTPUT_DIR}/asm/neon"
mkdir -p "${OUTPUT_DIR}/asm/sve"

NEON_OUTPUT="${OUTPUT_DIR}/neon"
SVE_LINKNAME_OUTPUT="${OUTPUT_DIR}/sve_linkname"
SVE_WRAPGOC_OUTPUT="${OUTPUT_DIR}/sve_wrapgoc"
NEON_ASM_DIR="${OUTPUT_DIR}/asm/neon"
SVE_ASM_DIR="${OUTPUT_DIR}/asm/sve"

# 检查simde子模块是否已拉取
echo ">>> Checking simde submodule..."
SIMDE_DIR="${PROJECT_DIR}/tools/simde"
SIMDE_INCLUDE_DIR="${PROJECT_DIR}/tools/simde/simde"
if [ ! -d "${SIMDE_DIR}" ] || [ ! -d "${SIMDE_DIR}/.git" ]; then
    echo ">>> simde submodule not found or not initialized."
    echo ">>> Initializing and updating simde submodule..."
    cd "${PROJECT_DIR}"
    git submodule update --init --recursive tools/simde
    if [ $? -ne 0 ]; then
        echo "Error: Failed to initialize simde submodule."
        exit 1
    fi
    cd "${SCRIPT_DIR}"
else
    echo ">>> simde submodule is already initialized."
fi

# 检查simde头文件是否存在
if [ ! -d "${SIMDE_INCLUDE_DIR}" ]; then
    echo "Error: simde include directory not found: ${SIMDE_INCLUDE_DIR}"
    echo "Please check if simde submodule is correctly initialized."
    exit 1
fi
echo ">>> simde include directory: ${SIMDE_INCLUDE_DIR}"
echo ""

echo ">>> Using ${CLANG_PATH} compiler"
echo ">>> Tool path: ${TOOL_PATH}"
echo ">>> Output directory: ${OUTPUT_DIR}"

# Resolve how to target aarch64, and prove the header environment is sane.
#
# The natives include glibc headers (native/parsing.h -> sys/types.h), so the
# compiler needs headers for the *target*, not the host. Cross-compiling without
# an aarch64 sysroot is the dangerous case: clang silently falls through to the
# host's /usr/include, where __WORDSIZE resolves for the host and ssize_t ends up
# as a 32-bit int. Every native taking or returning ssize_t is then miscompiled --
# with no error, no warning, and a zero exit status. The resulting natives pass a
# static inspection and then truncate lengths at runtime.
#
# On an arm64 host the native headers are already correct, so no extra flags are
# needed and the output is bit-identical to what this script always produced.
CLANG_TARGET_FLAGS=""
machine="$(uname -m)"
if [ "$machine" != "aarch64" ] && [ "$machine" != "arm64" ]; then
    SYSROOT="${AARCH64_SYSROOT:-}"
    if [ -z "${SYSROOT}" ]; then
        for cand in /usr/aarch64-linux-gnu /usr/aarch64-unknown-linux-gnu /usr/local/aarch64-linux-gnu; do
            if [ -d "${cand}" ]; then SYSROOT="${cand}"; break; fi
        done
    fi
    if [ -z "${SYSROOT}" ]; then
        echo "Error: cross-generating on ${machine} requires an aarch64 sysroot."
        echo "       Without one, clang uses this host's headers and silently"
        echo "       compiles ssize_t as a 32-bit int, miscompiling the natives."
        echo "  Debian/Ubuntu: sudo apt-get install libc6-dev-arm64-cross"
        echo "  Or point at one explicitly: AARCH64_SYSROOT=/path/to/sysroot $0"
        exit 1
    fi
    echo ">>> Cross-generating with sysroot: ${SYSROOT}"
    CLANG_TARGET_FLAGS="--target=aarch64-linux-gnu --sysroot=${SYSROOT}"
fi

# Belt and braces: assert the target's type widths regardless of how we got here.
verify_target_headers() {
    local probe_dir probe_c
    probe_dir="$(mktemp -d)"
    probe_c="${probe_dir}/probe.c"
    cat > "${probe_c}" <<'PROBE'
#include <sys/types.h>
#include <stdint.h>
_Static_assert(sizeof(ssize_t) == 8, "ssize_t is not 64-bit");
_Static_assert(sizeof(void *) == 8, "pointer is not 64-bit");
_Static_assert(sizeof(long) == 8, "long is not 64-bit");
PROBE
    if ! ${CLANG_PATH} ${CLANG_TARGET_FLAGS} -march=armv8-a+simd -fsyntax-only "${probe_c}" 2>"${probe_dir}/err"; then
        echo "Error: the target header environment is wrong -- refusing to generate."
        sed 's/^/    /' "${probe_dir}/err"
        echo "  These natives pass ssize_t across the Go/C boundary. Generating"
        echo "  against headers with the wrong type widths produces natives that"
        echo "  look fine but truncate lengths at runtime."
        rm -rf "${probe_dir}"
        exit 1
    fi
    rm -rf "${probe_dir}"
    echo ">>> Target header check passed (ssize_t/long/pointer are 64-bit)"
}

# 检查工具是否存在
if [ ! -f "${TOOL_PATH}" ]; then
    echo "Error: Tool not found. Please run build_tool.sh first."
    exit 1
fi

# 检查clang是否存在
if [ ! -f "${CLANG_PATH}" ]; then
    echo "Error: Clang not found. Please run build_tool.sh first."
    exit 1
fi

verify_target_headers

# 遍历native目录下的.c文件
echo ""
echo ">>> Processing native directory files..."
if [ -d "${SRC_DIR}" ]; then
    for src_file in "${SRC_DIR}"/*.c; do
        if [ -f "${src_file}" ]; then
            base_name="$(basename "${src_file}" .c)"

            echo ""
            echo ">>> Processing ${src_file}..."

            # 处理neon目录
            NEON_TMPL="${TMPL_DIR}/${base_name}.tmpl"
            if [ -f "${NEON_TMPL}" ]; then
                echo ""
                echo ">>> Processing for neon..."
                asm_file="${NEON_ASM_DIR}/${base_name}.s"
                cerr_log="${NEON_OUTPUT}/${base_name}.log"

                # 编译生成汇编文件（neon版本）
                echo ">>> Compiling to assembly (neon)... --> ${asm_file}"
                ${CLANG_PATH} \
                ${CLANG_TARGET_FLAGS} -g0 -fverbose-asm -fstack-usage -fsigned-char -Wa,--no-size-directive -fno-ident -fno-jump-tables \
                -ffixed-x28 -ffixed-x18 -ffixed-x9 -Wno-error -Wno-nullability-completeness -Wno-incompatible-pointer-types \
                -mllvm=--go-frame -mllvm=--enable-shrink-wrap=0 -mno-red-zone \
                -fno-stack-protector -nostdlib -O3 -fno-asynchronous-unwind-tables -fno-builtin -fno-exceptions \
                -march=armv8-a+simd -I${SIMDE_INCLUDE_DIR} -S -o "${asm_file}" "${src_file}"

                # 检查汇编文件是否生成
                if [ ! -f "${asm_file}" ]; then
                    echo "Error: Assembly file not generated for neon."
                else
                    echo ">>> Execute JIT mode for neon..."
                    ${TOOL_PATH} --debug --mode=JIT --source=${asm_file} --output=${NEON_OUTPUT} --link-ld=${SCRIPT_DIR}/link.ld --tmpl=${NEON_TMPL} \
                    --package=neon 2>${cerr_log}

                    if [ $? -eq 0 ]; then
                        echo ">>> Tool execution succeeded for neon ${base_name}"
                    else
                        echo ">>> Warning: Tool execution failed for neon ${base_name}. Check ${cerr_log} for details."
                    fi
                fi
            fi

            # 处理sve_linkname目录
            SVE_LINKNAME_FILE="${PROJECT_DIR}/internal/native/sve_linkname/${base_name}_arm64.go"
            if [ -f "${SVE_LINKNAME_FILE}" ]; then
                echo ""
                echo ">>> Processing for sve_linkname..."
                asm_file="${SVE_ASM_DIR}/${base_name}.s"
                cerr_log="${SVE_LINKNAME_OUTPUT}/${base_name}.log"

                echo ">>> Compiling to assembly (sve)... --> ${asm_file}"
                ${CLANG_PATH} \
                ${CLANG_TARGET_FLAGS} -g0 -fverbose-asm -fstack-usage -fsigned-char -Wa,--no-size-directive -fno-ident -fno-jump-tables \
                -ffixed-x28 -ffixed-x18 -ffixed-x9 -Wno-error -Wno-nullability-completeness -Wno-incompatible-pointer-types\
                -mllvm -disable-constant-hoisting -mllvm=--go-frame -fno-addrsig -no-integrated-as \
                -mno-red-zone -fno-stack-protector -nostdlib -O3 -fno-asynchronous-unwind-tables -fno-builtin -fno-exceptions \
                -march=armv8-a+sve+aes -I${SIMDE_INCLUDE_DIR} -D__SVE__ -S -o "${asm_file}" "${src_file}"

                # 检查汇编文件是否生成
                if [ ! -f "${asm_file}" ]; then
                    echo "Error: Assembly file not generated for sve_linkname."
                else
                    echo ">>> Execute SL mode for sve_linkname..."
                    ${TOOL_PATH} --debug --mode=SL --source=${asm_file} --goproto=${SVE_LINKNAME_FILE} --output=${SVE_LINKNAME_OUTPUT} --link-ld=${SCRIPT_DIR}/link.ld \
                    --package=sve_linkname --features=+sve,+aes --vl=32 2>${cerr_log}

                    if [ $? -eq 0 ]; then
                        echo ">>> Tool execution succeeded for sve_linkname ${base_name}"
                    else
                        echo "Warning: Tool execution failed for sve_linkname ${base_name}. Check ${cerr_log} for details."
                    fi
                fi
            fi

            # 处理sve_wrapgoc目录
            SVE_WRAPGOC_FILE="${PROJECT_DIR}/internal/native/sve_wrapgoc/${base_name}.go"
            SVE_WRAPGOC_TMPL="${PROJECT_DIR}/internal/native/${base_name}.tmpl"
            if [ -f "${SVE_WRAPGOC_FILE}" ] && [ -f "${SVE_WRAPGOC_TMPL}" ]; then
                echo ""
                echo ">>> Processing for sve_wrapgoc..."
                asm_file="${SVE_ASM_DIR}/${base_name}.s"
                cerr_log="${SVE_WRAPGOC_OUTPUT}/${base_name}.log"

                echo ">>> Compiling to assembly (sve)... --> ${asm_file}"
                ${CLANG_PATH} \
                ${CLANG_TARGET_FLAGS} -g0 -fverbose-asm -fstack-usage -fsigned-char -Wa,--no-size-directive -fno-ident -fno-jump-tables \
                -ffixed-x28 -ffixed-x18 -ffixed-x9 -Wno-error -Wno-nullability-completeness -Wno-incompatible-pointer-types\
                -mllvm -disable-constant-hoisting -mllvm=--go-frame -fno-addrsig -no-integrated-as \
                -mno-red-zone -fno-stack-protector -nostdlib -O3 -fno-asynchronous-unwind-tables -fno-builtin -fno-exceptions \
                -march=armv8-a+sve+aes -I${SIMDE_INCLUDE_DIR} -D__SVE__ -S -o "${asm_file}" "${src_file}"

                # 检查汇编文件是否生成
                if [ ! -f "${asm_file}" ]; then
                    echo "Error: Assembly file not generated for sve_wrapgoc."
                else
                    # Generate once per supported SVE vector length. --vl feeds
                    # only CalcSPDelta, so the machine code is identical every
                    # time; what differs is the frame accounting handed to Go,
                    # because scalable spill slots are VL bytes wide. Keeping one
                    # copy of the text and one small table per VL lets the
                    # vector length be chosen at load time instead of baked in.
                    echo ">>> Execute JIT mode for sve_wrapgoc (vl=32, vl=16)..."
                    for vl in 32 16; do
                        vl_dir="${SVE_WRAPGOC_OUTPUT}/vl${vl}"
                        mkdir -p "${vl_dir}"
                        ${TOOL_PATH} --debug --mode=JIT --source=${asm_file} --output=${vl_dir} --link-ld=${SCRIPT_DIR}/link.ld --tmpl=${SVE_WRAPGOC_TMPL} \
                        --package=sve_wrapgoc --features=+sve,+aes --vl=${vl} 2>>${cerr_log}
                    done

                    # text and stub are vector-length agnostic: take either copy.
                    cp "${SVE_WRAPGOC_OUTPUT}/vl32/${base_name}_text_arm64.go" "${SVE_WRAPGOC_OUTPUT}/" 2>/dev/null
                    cp "${SVE_WRAPGOC_OUTPUT}/vl32/${base_name}.go" "${SVE_WRAPGOC_OUTPUT}/" 2>/dev/null
                    # merge_vl_subr.py refuses if entry/size differ, i.e. if the
                    # text ever stops being vector-length agnostic.
                    python3 "${SCRIPT_DIR}/merge_vl_subr.py" \
                        32 "${SVE_WRAPGOC_OUTPUT}/vl32/${base_name}_subr.go" \
                        16 "${SVE_WRAPGOC_OUTPUT}/vl16/${base_name}_subr.go" \
                        "${SVE_WRAPGOC_OUTPUT}/${base_name}_subr.go"

                    if [ $? -eq 0 ]; then
                        echo ">>> Tool execution succeeded for sve_wrapgoc ${base_name}"
                    else
                        echo "Warning: Tool execution failed for sve_wrapgoc ${base_name}. Check ${cerr_log} for details."
                    fi
                fi
            fi
        fi
    done
else
    echo "Warning: native directory not found: ${SRC_DIR}"
fi

echo ""
echo ">>> All files processed!"
echo ">>> Output files are in: ${OUTPUT_DIR}"

# 如果指定了清理选项，执行清理
if [ "$CLEAN" = "true" ]; then
  clean_files
fi
