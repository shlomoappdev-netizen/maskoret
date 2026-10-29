#!/bin/zsh
# Compiles tool/swift_check/main.swift with the Swift app's real model code and runs it on a household JSON.
# Usage: tool/swift_check.sh <household.json> <now as Swift reference-date seconds>
set -e
here=${0:A:h}
src=$here/../../Maskoret
build=${TMPDIR:-/tmp}/maskoret_swift_check
mkdir -p $build
# The parts of Store.swift / Family.swift / Components.swift that the models need (no SwiftUI).
{ echo 'import Foundation'; awk '/^enum Fmt \{/,/^\}/' $src/Components.swift; } > $build/Fmt.swift
{ echo 'import Foundation'; echo 'enum Store {'; awk '/    struct SaveFile: Codable \{/,/^    \}$/' $src/Store.swift; echo '}'; } > $build/SaveFile.swift
{ echo 'import Foundation'; awk '/^struct FamilyMember/,/^\/\/ MARK: - What the dashboards/' $src/Family.swift | sed '$d'; } > $build/FamilyTypes.swift
# The model files themselves, without their `extension Store { … }` blocks (those need the whole app).
models=()
for f in Models TaxRates Money Card Maaser Trends Receivables; do
  awk '/^extension Store \{/{skip=1} !skip{print} skip&&/^\}/{skip=0}' $src/$f.swift > $build/$f.swift
  models+=$build/$f.swift
done
swiftc -O -o $build/check $here/swift_check/main.swift $build/Fmt.swift $build/SaveFile.swift $build/FamilyTypes.swift $models
$build/check "$@"
