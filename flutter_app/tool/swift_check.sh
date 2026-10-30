#!/bin/zsh
# Compiles tool/swift_check/main.swift with the Swift app's real model code and runs it on a household JSON.
# Usage: tool/swift_check.sh <household.json> <now as Swift reference-date seconds>
set -e
here=${0:A:h}
src=$here/../../Maskoret
cache=${TMPDIR:-/tmp}/maskoret_swift_check
# Each run writes its intermediate files in its own folder (tests run in parallel).
build=$cache/run.$$
mkdir -p $build
trap 'rm -rf $build' EXIT
# The parts of Store.swift / Family.swift / Components.swift that the models need (no SwiftUI).
{ echo 'import Foundation'; awk '/^enum Fmt \{/,/^\}/' $src/Components.swift; } > $build/Fmt.swift
{ echo 'import Foundation'; echo 'enum Store {'; awk '/    struct SaveFile: Codable \{/,/^    \}$/' $src/Store.swift; echo '}'; } > $build/SaveFile.swift
{ echo 'import Foundation'; awk '/^struct FamilyMember/,/^\/\/ MARK: - What the dashboards/' $src/Family.swift | sed '$d'
  awk '/^struct DataSnapshot \{/,/^\}/' $src/Family.swift; } > $build/FamilyTypes.swift
# The model files themselves, without their `extension Store { … }` blocks (those need the whole app).
models=()
for f in Models TaxRates Money Card Maaser Trends Receivables; do
  awk '/^extension Store \{/{skip=1} !skip{print} skip&&/^\}/{skip=0}' $src/$f.swift > $build/$f.swift
  models+=$build/$f.swift
done
# The month calculation ("נשאר בסוף החודש") from Sync.swift: the MonthPicture struct, and Store.monthPicture
# turned into a free function over `dashboard` (set by main.swift).
{ echo 'import Foundation'
  awk '/^struct MonthPicture \{/,/^\}/' $src/Sync.swift
  awk '/^    func monthPicture\(year: Int, month: Int, budget override: Budget\? = nil\) -> MonthPicture \{/,/^    \}$/' $src/Sync.swift
} > $build/MonthPicture.swift
sources=($here/swift_check/main.swift $build/Fmt.swift $build/SaveFile.swift $build/FamilyTypes.swift $build/MonthPicture.swift $models)
# Compiled once per version of the sources (tests run in parallel and share it).
hash=$(cat $sources | shasum | cut -c1-16)
bin=$cache/check-$hash
if [ ! -x $bin ]; then
  swiftc -O -o $bin.$$ $sources
  mv -f $bin.$$ $bin
fi
$bin "$@"
