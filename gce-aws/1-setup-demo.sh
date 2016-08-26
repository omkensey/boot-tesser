#!/bin/bash

source ./demo-env.sh

gcloud compute instances create $MASTER --image-project $PROJECT --image-family $IMAGE --tags apiserver
gcloud compute instances create $WORKERS --image-project $PROJECT --image-family $IMAGE

sleep 5

for node in $MASTER $WORKERS; do
  gcloud compute copy-files prep-non-coreos-node.sh bootkube@${node}:
  gcloud compute ssh --ssh-flag="-t" bootkube@${node} sudo ./prep-non-coreos-node.sh
done
