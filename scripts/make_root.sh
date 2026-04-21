#!/bin/bash
set -e
ROOT_FOLDER="$1"
OUTPUT="$2"    # root.ext2
SIZE_MB="${3:-64}"

genext2fs -b $((SIZE_MB * 1024)) -d "$ROOT_FOLDER" "$OUTPUT"
