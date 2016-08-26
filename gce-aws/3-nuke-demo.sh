#!/bin/bash

source ./demo-env.sh

rm -rf $CLUSTER_DIR
ssh-keygen -R $(gcloud compute instances describe --format json $MASTER | jq -r '.networkInterfaces | .[].accessConfigs | .[].natIP') -f ~/.ssh/known_hosts
for worker in $WORKERS; do
  ssh-keygen -R $(gcloud compute instances describe --format json $worker | jq -r '.networkInterfaces | .[].accessConfigs | .[].natIP') -f ~/.ssh/known_hosts
done

gcloud compute instances delete $MASTER $WORKERS
