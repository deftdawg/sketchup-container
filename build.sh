#!/usr/bin/env bash

export DISPLAY=:0
xhost +
podman build --ulimit nofile=32767 --net=host --ipc=host --pid=host -t sketchup .

