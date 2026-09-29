#!/usr/bin/env bash
# Links a guest object against a zkVM SDK, after checking the guest object against the ABI.
#
# The guest object is a static archive of LLVM bitcode (plus native compiler builtins) that defines
# `main`. It must leave nothing undefined that is not in the guest ABI (`abi.txt`), or it would
# depend on one vendor's internals. It may define an ABI symbol, such as its own `zkvm_keccak256`:
# that definition replaces the SDK's, with a warning, and the SDK's copy stays in use only inside
# the vendor's own code. If the SDK has a `zkvm.features` file, its ISA extensions are then added to
# the guest's code (below). The link is the one fixed command, so the ELF depends only on the guest
# object, the SDK and the linker.
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
clash=$(comm -12 <(echo "$abi") <(echo "$defined"))
if extra=$(comm -13 <(echo "$abi") <(echo "$undefined")) && [[ -n $extra ]]; then
    echo "$guest: needs symbols outside the guest ABI:" $extra >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zkvm-link.XXXXXX")
trap 'rm -rf "$work"' EXIT

is_bitcode() { [[ $(head -c 4 "$1" | xxd -p) == 4243c0de ]]; }

# ABI symbols the guest defines replace the SDK's. The SDK's copies are made internal, in a copy of
# the SDK, so that the guest's are the only ones the link sees: in a fat LTO object's bitcode, which
# the link reads, with `opt`, and in any other native member with `llvm-objcopy`.
if [[ -n $clash ]]; then
    echo "warning: $guest replaces the SDK's" $clash >&2
    mkdir -p "$work/sdk/lib"
    for file in "$sdk"/*; do [[ $file == */libzkvm.a ]] || ln -s "$(cd "$(dirname "$file")" && pwd)/$(basename "$file")" "$work/sdk/"; done
    localize=()
    while read -r symbol; do localize+=("--localize-symbol=$symbol"); done <<<"$clash"
    sdk_members=()
    while IFS= read -r member; do sdk_members+=("$member"); done < <("$LLVM_BIN/llvm-ar" t "$sdk/libzkvm.a")
    (cd "$work/sdk/lib" && "$LLVM_BIN/llvm-ar" x "$(cd "$sdk" && pwd)/libzkvm.a")
    for i in "${!sdk_members[@]}"; do
        member=$work/sdk/lib/${sdk_members[$i]}
        if "$LLVM_BIN/llvm-objcopy" --dump-section .llvm.lto="$member.bc" "$member" 2>/dev/null; then
            public=$("$LLVM_BIN/llvm-nm" --defined-only --extern-only "$member.bc" | awk '{print $NF}' |
                grep -vxF -f <(echo "$clash") | paste -sd, -)
            "$LLVM_BIN/opt" "$member.bc" -o "$member.bc" -passes=internalize -internalize-public-api-list="$public"
            sdk_members[$i]=${sdk_members[$i]}.bc
        else
            "$LLVM_BIN/llvm-objcopy" "${localize[@]}" "$member"
        fi
    done
    (cd "$work/sdk/lib" && "$LLVM_BIN/llvm-ar" rcs ../libzkvm.a "${sdk_members[@]}")
    sdk=$work/sdk
fi

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
        is_bitcode "$work/$member" || continue
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
