#!/bin/sh
# Until DRT ships `require`, a module is tested by wrapping it in an IIFE and
# concatenating the cases. When require lands this becomes two require lines.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DRT="${DRT:-/tmp/dfwg/drt}"
command -v "$DRT" >/dev/null 2>&1 || [ -x "$DRT" ] || { echo "no drt: set \$DRT" >&2; exit 1; }
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
{ printf 'local M = (function()\n'; cat "$here/../db.dlua"; printf 'end)()\n'; cat "$here/cases.dlua"; } > "$out/all.dlua"
"$DRT" run "$out/all.dlua"
