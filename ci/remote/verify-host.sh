#!/usr/bin/env bash
# Runs on the EC2 host. Confirms via the instance metadata service (IMDSv2)
# that we are connected to the intended EC2 instance, and that K3s is
# reachable through non-interactive sudo kubectl.
#
# Usage: verify-host.sh <workdir> <expected-instance-id> <expected-private-ip>
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <workdir> <expected-instance-id> <expected-private-ip>" >&2
  exit 2
fi
EXPECTED_ID=$2
EXPECTED_IP=$3
IMDS=http://169.254.169.254/latest

token=$(curl -sS --fail --max-time 5 -X PUT "$IMDS/api/token" \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
meta() { curl -sS --fail --max-time 5 -H "X-aws-ec2-metadata-token: $token" "$IMDS/meta-data/$1"; }

instance_id=$(meta instance-id)
private_ip=$(meta local-ipv4)
region=$(meta placement/region)

echo "[verify-host] hostname=$(hostname) instance-id=$instance_id private-ip=$private_ip region=$region"

if [[ "$instance_id" != "$EXPECTED_ID" ]]; then
  echo "[verify-host] ERROR: connected to instance $instance_id, expected $EXPECTED_ID. Refusing to deploy." >&2
  exit 1
fi
if [[ "$private_ip" != "$EXPECTED_IP" ]]; then
  echo "[verify-host] ERROR: private IP is $private_ip, expected $EXPECTED_IP. Refusing to deploy." >&2
  exit 1
fi

if ! sudo -n kubectl get nodes -o wide; then
  echo "[verify-host] ERROR: 'sudo -n kubectl' is not usable on this host." >&2
  exit 1
fi
echo "[verify-host] OK: intended EC2 instance confirmed and K3s API reachable locally."
