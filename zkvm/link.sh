#!/usr/bin/env bash
# Links a guest object against a zkVM SDK, after checking the guest object against the ABI.
#
# The guest object is a static archive of LLVM bitcode (plus native compiler builtins) that defines
# `main`. It must define no symbol of the guest ABI in `abi.txt`, and leave nothing undefined that
# is not in it; otherwise the link could silently take a guest definition over the vendor's, or
# depend on one vendor's internals. If the SDK has a `zkvm.features` file, its ISA extensions are
# then added to the guest's code (below). The link is the one fixed command, so the ELF depends
# only on the guest object, the SDK and the linker.
#
# The SDK's `libzkvm.a` holds fat LTO objects, and the link reads their bitcode
# (`--fat-lto-objects`), so guest and SDK are optimized as one module. If the SDK carries an LLVM
# pass plugin (`zkvm-lto-plugin.so`, built for the linker's LLVM), the link loads it into the LTO
# pipeline. The arguments after the output are LLVM options for this guest on this zkVM (e.g. SP1's
# `-misched-prera-direction=bottomup`, or `--inline-threshold=4749`), passed as `-mllvm`. They are
# part of the link command, so the ELF depends on them too.
#
# Usage: link.sh <sdk-dir> <guest.a> <out.elf> [llvm-option...]
# Requires: `ld.lld` (LD_LLD) with an LLVM at least as new as the guest's and the SDK's bitcode, and
# `llvm-nm`, `llvm-ar`, `llvm-dis` and `llvm-as` (LLVM_BIN).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sdk=$1 guest=$(cd "$(dirname "$2")" && pwd)/$(basename "$2") out=$3
shift 3
lto_args=()
for arg in "$@"; do lto_args+=(-mllvm "$arg"); done
[[ -f $sdk/zkvm-lto-plugin.so ]] && lto_args+=("--load-pass-plugin=$sdk/zkvm-lto-plugin.so")
LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm@22/bin}
LD_LLD=${LD_LLD:-ld.lld}

abi=$(sort -u "$here/abi.txt")
defined=$("$LLVM_BIN/llvm-nm" --defined-only --extern-only "$guest" 2>/dev/null |
    awk 'NF >= 3 && $(NF-1) ~ /^[TDBR]$/ {print $NF}' | sort -u)
undefined=$(comm -23 \
    <("$LLVM_BIN/llvm-nm" --undefined-only "$guest" 2>/dev/null | awk 'NF >= 2 {print $NF}' | sort -u) \
    <("$LLVM_BIN/llvm-nm" --defined-only "$guest" 2>/dev/null | awk 'NF >= 2 {print $NF}' | sort -u))

grep -qx main <<<"$defined" || { echo "$guest: does not define main" >&2; exit 1; }
if clash=$(comm -12 <(echo "$abi") <(echo "$defined")) && [[ -n $clash ]]; then
    echo "$guest: defines guest ABI symbols:" $clash >&2
    exit 1
fi
if extra=$(comm -13 <(echo "$abi") <(echo "$undefined")) && [[ -n $extra ]]; then
    echo "$guest: needs symbols outside the guest ABI:" $extra >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zkvm-link.XXXXXX")
trap 'rm -rf "$work"' EXIT

# The guest is built for plain RV64IM. The ISA extensions this zkVM supports (`zkvm.features`) are
# added to the guest's code here, so one guest object serves every zkVM. They go into each
# function's `target-features` attribute, because that attribute replaces, not extends, the
# features `ld.lld` would otherwise give code generation. Features are only ever added.
if [[ -s $sdk/zkvm.features ]]; then
    features=$(tr -d '[:space:]' <"$sdk/zkvm.features")
    [[ $features =~ ^(\+[a-z0-9.-]+)(,\+[a-z0-9.-]+)*$ ]] || {
        echo "$sdk/zkvm.features: expected +feature[,+feature...], got '$features'" >&2
        exit 1
    }
    members=()
    while IFS= read -r member; do members+=("$member"); done < <("$LLVM_BIN/llvm-ar" t "$guest")
    (cd "$work" && "$LLVM_BIN/llvm-ar" x "$guest")
    for member in "${members[@]}"; do
        [[ $(head -c 4 "$work/$member" | xxd -p) == 4243c0de ]] || continue
        "$LLVM_BIN/llvm-dis" "$work/$member" -o - |
            sed -E -e "s/\"target-features\"=\"\"/\"target-features\"=\"$features\"/g" \
                -e "s/(\"target-features\"=\"[^\"]+)\"/\1,$features\"/g" |
            "$LLVM_BIN/llvm-as" -o "$work/$member.tmp"
        mv "$work/$member.tmp" "$work/$member"
    done
    (cd "$work" && "$LLVM_BIN/llvm-ar" rcs guest.a "${members[@]}")
    guest=$work/guest.a
fi

"$LD_LLD" -T "$sdk/zkvm.ld" -L "$sdk" --gc-sections --fat-lto-objects --lto-O3 ${lto_args[@]+"${lto_args[@]}"} -o "$out" "$guest"
echo "$out"
