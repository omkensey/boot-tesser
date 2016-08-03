# GCE and AWS quickstart

To use this version of the bookube quickstart on non-CoreOS hosts:

## GCE prep

1. Launch nodes:

```
$ gcloud compute instances create k8s-self-master k8s-self-worker --machine-type n1-standard-1 --image rhel-7
[...]
NAME            ZONE       MACHINE_TYPE  PREEMPTIBLE INTERNAL_IP EXTERNAL_IP     STATUS
k8s-self-master us-east1-c n1-standard-1             10.240.0.3  104.196.120.215 RUNNING
```

Note the public IP.

2. Allow traffic to port 443 on the API server node(s):

```
$ gcloud compute instances add-tags k8s-self-master --tags apiserver
$ gcloud compute firewall-rules create api-443 --target-tags=apiserver --allow tcp:443
```

## AWS prep

1. Create a security group for the instances you're about to create:

```
$ aws ec2 create-security-group --region us-west-2 --group-name k8s-sg --description "Security group for k8s cluster"
GroupID: "sg-abcdefg"
```

Note the GroupID that is output.

2. Create the security group rules:

```
$ aws ec2 authorize-security-group-ingress --region us-west-2 --group-name k8s-sg --protocol tcp --port 22 --cidr 0.0.0.0/0
$ aws ec2 authorize-security-group-ingress --region us-west-2 --group-name k8s-sg --protocol tcp --port 443 --cidr 0.0.0.0/0
$ aws ec2 authorize-security-group-ingress --region us-west-2 --group-name k8s-sg --protocol tcp --port 0-65535 --source-group k8s-sg
```

3. Create a keypair:

```
$ aws ec2 create-key-pair --key-name k8s-key --query 'KeyMaterial' --output text > k8s-key.pem
$ chmod 400 k8s-key.pem
```

4. Launch nodes (replace `<K8S_SG_ID>` below with the GroupID you noted earlier):

```
$ aws ec2 run-instances --region us-west-2 --image-id ami-184a8f78 --security-group-ids <K8S_SG_ID> --count 1 --instance-type m3.medium --key-name k8s-key --query 'Instances[0].InstanceId'
"i-abcdefgh"
```

5. Get the new instance's public IP address (replace `<INSTANCE_ID>` below with the ID output by the previous command):

```
$ aws ec2 describe-instances --region us-west-2 --instance-ids <INSTANCE_ID> --query 'Reservations[0].Instances[0].PublicIpAddress'
```

## Host prep and install

1. Copy the `prep-non-coreos-master.sh` script to the target host.  Execute it there, using an account that can sudo without a password:

`$ sudo ./prep-non-coreos-master.sh`

2. Run the `init-master.sh` script on your client (laptop, desktop, etc.) with the public IP of the master instance and the IDENT variable set to the appropriate SSH key filename:

`$ IDENT=~/.ssh/google_compute_engine ./init-master.sh <node-public-ip>`

Eventually you should see a message that bootstrap is complete with instructions on how to access your new master node.
