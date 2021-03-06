#!/usr/bin/env bash

############################################################################
# WARNING: This script is experimental and is not meant for production use #
############################################################################
#
# Script to retrieve configuration from Hashicorp Consul Service on Azure,
# bootstrap ACLs, and set configuration files for HCS based Virtual Machine 
# deployments

set -euo pipefail

: "${subscription_id?subscription_id environment variable required}"
: "${resource_group?resource_group environment variable required}"
: "${managed_app_name?managed_app_name environment variable required}"
: "${cluster_name?cluster_name environment variable required}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;93m'
NOCOLOR='\033[0m'

echo -e "${YELLOW}-> Fetching cluster configuration from Azure${NOCOLOR}"
cluster_resource=$(az resource show --ids "/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Solutions/applications/${managed_app_name}/customconsulClusters/${cluster_name}" --api-version 2018-09-01-preview)
cluster_config_file_base64=$(echo "${cluster_resource}" | jq -r .properties.consulConfigFile)
ca_file_base64=$(echo "${cluster_resource}" | jq -r .properties.consulCaFile)

echo "Writing cluster configuration to consul.json"
echo "${cluster_config_file_base64}" | base64 --decode | jq . > consul.json

echo "Writing CA certificate chain to ca.pem"
echo "${ca_file_base64}" | base64 --decode > ca.pem
echo

echo -e "${YELLOW}-> Bootstrapping ACLs${NOCOLOR}"

# Extract the URL for the servers.
# First, check if the external endpoint is enabled and if yes, use the external endpoint URL.
# Otherwise, use the private endpoint URL.
external_endpoint_enabled=$(echo "${cluster_resource}" | jq -r .properties.consulExternalEndpoint)
if [ "$external_endpoint_enabled" == "enabled" ]; then
  server_url=$(echo "${cluster_resource}" | jq -r .properties.consulExternalEndpointUrl)
else
  server_url=$(echo "${cluster_resource}" | jq -r .properties.consulPrivateEndpointUrl)
fi

output=$(curl --connect-timeout 30 -sSX PUT "${server_url}"/v1/acl/bootstrap)
if grep -i "permission denied" <<< "$output"; then
  echo "ACL system already bootstrapped."
  acl="Update With current bootstrap ACL"
elif  grep -i "ACL support disabled" <<< "$output"; then
  echo -e "${RED}ACLs not enabled on this cluster.${NOCOLOR}"
  exit 1
else
  echo "Successfully bootstrapped ACLs. Writing ACL bootstrap output to acls.json"
  echo "$output" > acls.json
  acl=$(echo "${output}" | jq -r '.SecretID')
fi

echo

gossip_key=$(jq -r .encrypt consul.json)
retry_join=$(jq -r --compact-output .retry_join consul.json)
consul_version=$(echo "${cluster_resource}" | jq -r .properties.consulInitialVersion | cut -d'v' -f2)

echo
echo -e "${YELLOW}-> Writing Consul server config to consul.config.json${NOCOLOR}"
cat > consul.config.json << EOF
{
    "ca_file": "/etc/consul.d/client/ca.pem",
    "verify_outgoing": true,
    "datacenter": "$(jq -r .datacenter consul.json)",
    "encrypt": "$(jq -r .encrypt consul.json)",
    "server": false,
    "connect": {
      "enabled": true
    },
    "ports": {
      "grpc": 8502
    },
    "data_dir": "/var/consul",
    "log_level": "INFO",
    "ui": true,
    "retry_join": $(jq -r .retry_join consul.json),
    "auto_encrypt": {
      "tls": true
    },
    "acl": {
      "enabled": true,
      "down_policy": "async-cache",
      "default_policy": "deny",
      "tokens": {
        "default": "${acl}"
      }
    }
}
EOF


echo
echo -e "${GREEN}Done${GREEN}"
echo -e "${GREEN}You can view the original Consul configuration in the consul.json file in this directory${GREEN}"