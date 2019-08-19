#!/bin/bash

echo "Rename files"

id=0
for filename in ./*.wav; do
#    echo $filename;
#if ! ((id % 2)); then
#    echo $id
#    rm $filename
#fi
#    mv $filename "Pencil$id.wav"
    ffmpeg -i $filename "$id.mp3"
    id=$((id + 1))
done
