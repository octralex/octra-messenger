#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2023-2026 Octra Labs <dev@octra.org>
set -euo pipefail

# Builds the wallet and the messenger endpoint. Run from this directory.
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT=$(CDPATH= cd -- "$HERE/.." && pwd)
export MESSENGER_SCRATCH=${MESSENGER_SCRATCH:-$HERE/.messenger-build}

cp "$PROJECT/programs/segment.aml" "$HERE/static/messenger-segment.aml"
make -C "$HERE"
mkdir -p "$MESSENGER_SCRATCH"
"$PROJECT/tests/build_endpoint.sh" "$HERE/messenger_endpoint"
printf 'built %s and %s\n' "$HERE/octra_wallet" "$HERE/messenger_endpoint"
