# CoreOS Self-Hosted Kubernetes on RHEL and Ubuntu

## Intent

The idea is to carry out enough modifications to a non-CoreOS host to allow it to be a base for the CoreOS Kubernetes self-hosted install.  This encompasses both a relatively large prep script (`prep-non-coreos-node.sh`) and some small modifications to the install scripts.

## Execution

The preparation steps undertaken consist of the following:

### Identify the system

In the beginning we start off by checking for systemd.  If it's not there, 
none of the following will work, so we exit with an error.  If it is 
there, we go ahead and initialize some variables for later use.

Next we identify which systemd-based distribution we're on.  If it's RHEL 
7.x or Ubuntu 16.x, we record that and set a few distro-specific 
variables and config options.  If it's CoreOS, we just exit.  If it's 
something else, we exit with an error.

### Pull metadata

Next we try to identify whether we're on a cloud provider we know about 
-- right now that means GCE or AWS.  If it's either of those, we pull IP 
metadata and record it.  If it's not, we exit with an error.

For bare-metal installs, it *should* be fine to do the following before 
you run this script:

* comment out the `exit 1` in the catchall of the case statement
* add your own metadata in a file under /var/coreos called 
`metadata-[something].conf`, or alternately just set the 
COREOS_PUBLIC_IPV4 and COREOS_PRIVATE_IPV4 environment variables

Finally we write the gathered metadata to a file under /var/coreos and 
roll it all up into /var/coreos/metadata.

### Install packages

There are a few services and utilities that aren't in the base install of 
either RHEL or Ubuntu that we need.  Most of these are installable from 
packages.  A few notes:

* On RHEL we install jq from package URLs in EPEL, which means we first 
import the EPEL key (we actually did the key import back during the 
OS-identification step).  We *do not* add EPEL as a repository.
* RHEL also has the default flannel network key prefix changed from 
`/coreos.com/network` to `/atomic.io/network`.  Why, Red Hat, why??  We 
change it back so that RHEL is put back into a consistent config with 
other distros.
* Ubuntu auto-starts etcd on package install.  Why, Canonical, why??  We 
stop it because otherwise it won't pick up our changes to its 
configuration later.  In future we will probably also clean out the member 
directory to allow for creating multi-node etcd clusters.
* Ubuntu also has no flannel package in an official repo, so we download a 
release tarball and install from that.

### Firewall rules

NOTE: it's highly likely that this entire section will go away in the 
future, so don't spend a lot of time coming up with automated fixes.

To try and smooth the install, we allow ports 443 and 2379 in on the host 
firewall if we can determine what it is.  This is kind of ugly though and 
rather than add more rules this section should probably just go away.

The basic rules for Kubernetes are:

* etcd servers (which may be Kubernetes master nodes) need to allow port 
2379 traffic from clients and port 2380 traffic from peers
* API servers (Kubernetes master nodes) need to allow HTTPS traffic from 
other nodes and from any host where kubectl will be run
* Worker nodes need to allow traffic as the applications running on them 
require.

In addition to those you will want the basics like SSH connectivity, and 
whatever else is needed for your infrastructure monitoring, alerting, 
coffeemaking, whatever it is you do.

### User setup

Pretty much everything written for CoreOS assumes a `core` user endowed 
with passwordless sudo powers.  That's pretty rare in other distros (you 
might have a first user who gets sudo by default, but usually not 
passwordless).

* If `core` doesn't exist, we create it.
* If `core` doesn't have passwordless sudo, we grant it.

### Install rkt

Again there's no distro package for rkt in either RHEL or Ubuntu.  To 
minimize the impact on install scripts that assume rkt is installed, we 
install it from a tarball.  Prior to doing that, we create the `rkt` and 
`rkt-admin` groups and add the `core` user to them.

### Install kubelet-wrapper

CoreOS uses a wrapper script to run the kubelet from a container, so we 
pull that down from GitHub and put it where other things will expect it 
to be.

### Cleanup

As we went through the stages, we built a list of tarballs we downloaded, 
directories we extracted out of them, etc.  At the very end we nuke it 
all.

## Other modifications made

The init-master.sh and init-worker.sh scripts get a few modifications 
as well.

### init-master.sh script

Very minor changes here.

* CoreOS calls etcd version 2 `etcd2`.  RHEL calls etcd version 2 
`etcd`.  Ubuntu calls etcd version 2 `etcd` but the systemd unit file 
has an alias to the name `etcd2`.  To account for the variations we 
source our environment file and do some if-dancing.
* We also genericize some things that were hardcoded -- for example, RHEL 
and Ubuntu have `ln` in different places.
* Only CoreOS has update-engine so we only stop and mask it if the OS is 
CoreOS.
* SSH needs to request a TTY to allow the script to sudo itself remotely 
because some systems don't allow sudo on a non-tty.
* There are some style changes.

### init-worker.sh script

* Same notes about genericization, update-engine, SSH and style.

### Master and worker kubelet units

The only thing we do here is add an EnvironmentFile statement to refer 
optionally to /var/coreos/metadata so that we can pass our accumulated 
environment to the kubelet unit (it needs to know the public and 
private IPs)

## Run a demo

There are three demo scripts, and a demo-env.sh file, that will run a 
full cycle of the quickstart on GCE.  You need `gcloud` and `jq` 
installed and configured.

* Customize demo-env.sh with the instance names, OS images, etc. that 
you want.
* Run 1-setup-demo.sh.  This will create the instances.
* Run 2-run-demo.sh.  This will install the Kubernetes master and worker.
* After you're done, run 3-nuke-demo.sh and it will delete the instances 
and remove their host keys from your ~/.ssh/known_hosts file.
