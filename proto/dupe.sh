#!/bin/bash

for TYPE in gw vm; do
  cp source-${TYPE}-init.yaml-proto destination-${TYPE}-init.yaml-proto 
done

exit 0
