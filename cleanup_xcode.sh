#!/bin/bash
# Script to cleanup xcode runtime files

base="$HOME/Library/Containers/mcdow.nana/Data"
rm "$base/db.db";
rm "$base/*vecs.db";
find $base -name "[0-9]*" -type f | xargs -I {} bash -c "rm '{}'";
