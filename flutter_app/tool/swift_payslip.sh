#!/bin/zsh
# Compiles tool/swift_payslip/main.swift with the Swift app's Payslip.swift and parses the texts given on stdin
# (a JSON array of strings), printing what PayslipReader.parse reads from each.
set -e
here=${0:A:h}
src=$here/../../Maskoret
cache=${TMPDIR:-/tmp}/maskoret_swift_check
mkdir -p $cache
sources=($here/swift_payslip/main.swift $src/Payslip.swift)
hash=$(cat $sources | shasum | cut -c1-16)
bin=$cache/payslip-$hash
if [ ! -x $bin ]; then
  swiftc -O -o $bin.$$ $sources
  mv -f $bin.$$ $bin
fi
$bin
