#!/bin/bash

#echo "Rename files"

id=0
for filename in ./*.wav; do

ffmpeg -i $filename -af "pan=mono|c0=c0" -y "mono.wav"
normalize mono.wav

DUR="$(afinfo $filename | grep duration: | sed 's/^.*: //' | awk '{print $1}')"
DUR2=${DUR%.*} #int

if [ $DUR2 -gt 9 ]
    then
  ffmpeg -i "mono.wav" -to 10 -c copy -y "cropped.wav" #crop
    # Add fadeout here!
    echo "Fade out"
     ffmpeg -i "cropped.wav" -af "afade=t=out:st=9.5:d=0.5" -y "$id.wav"
else
mv mono.wav "$id.wav"
fi
    id=$((id + 1))
done

rm cropped.wav
rm mono.wav
