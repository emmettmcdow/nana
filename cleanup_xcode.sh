#!/bin/bash
# Script to cleanup xcode runtime files

base="$HOME/Library/Containers/mcdow.nana/Data"
rm "$base/db.db";
find $base -regex "[0-9]+" -type f | xargs rm;
