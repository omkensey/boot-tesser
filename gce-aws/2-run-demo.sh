#!/bin/bash

source ./demo-env.sh

./init-master.sh $(gcloud compute instances describe --format json $MASTER | jq -r '.networkInterfaces | .[].accessConfigs | .[].natIP')
sleep 5
mv cluster $CLUSTER_DIR
kubectl --kubeconfig=${CLUSTER_DIR}/auth/kubeconfig get nodes
sleep 5
for worker in $WORKERS; do
  ./init-worker.sh $(gcloud compute instances describe --format json $worker | jq -r '.networkInterfaces | .[].accessConfigs | .[].natIP') ${CLUSTER_DIR}/auth/kubeconfig
done
sleep 2
watch -n 1 kubectl --kubeconfig=${CLUSTER_DIR}/auth/kubeconfig get nodes
