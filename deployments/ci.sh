#!/bin/bash
# Utility script to deploy Penumbra testnet(s) to k8s,
# used as part of CI. At a high level, this script does the following:
#
#  * reads env vars (e.g. from github actions) to set helm values
#  * runs a container with `pd testnet generate` to create genesis
#  * munges the generated data into valid (but internal) peer strings
#  * deploys helm chart to kubernetes cluster, replacing running pods
#  * waits a while, then fetches the public ip addresses
#  * re-munges the generated data into publicly-routable peer strings
#  * re-deploys the helm chart to overwrite the config
#
set -euo pipefail

# The following env vars can be used to override config fars
# for the helm chart. N.B. these env vars are also configured
# in GitHub Actions, so the values below may be out of date.
WORKDIR="${WORKDIR:=$(pwd)/charts/penumbra/pdcli}"
IMAGE="${IMAGE:-ghcr.io/penumbra-zone/penumbra}"
PENUMBRA_VERSION="${PENUMBRA_VERSION:-main}"
PENUMBRA_UID_GID="${PENUMBRA_UID_GID:-1000\:1000}"
TENDERMINT_VERSION="${TENDERMINT_VERSION:-v0.34.23}"
NVALS="${NVALS:-2}"
NFULLNODES="${NFULLNODES:-2}"
CONTAINERHOME="${CONTAINERHOME:-/root}"
# Default to preview for deployments; less likely to break public testnet.
HELM_RELEASE="${HELM_RELEASE:-penumbra-testnet-preview}"

# Check that the network we're trying to configure has a valid config.
if [[ "$HELM_RELEASE" =~ ^penumbra-testnet$ ]] ; then
    HELM_VARS_FILE="networks/testnet/helm-values-for-${HELM_RELEASE}.yml"
elif [[ "$HELM_RELEASE" =~ ^penumbra-testnet-preview$ ]] ; then
    HELM_VARS_FILE="networks/testnet-preview/helm-values-for-${HELM_RELEASE}.yml"
elif [[ "$HELM_RELEASE" =~ ^penumbra-devnet$ ]] ; then
    HELM_VARS_FILE="networks/devnet/helm-values-for-${HELM_RELEASE}.yml"
else
    >&2 echo "ERROR: helm release name '$HELM_RELEASE' not supported"
    exit 1
fi
if [[ ! -e "$HELM_VARS_FILE" ]]; then
    >&2 echo "ERROR: file not found: '$HELM_VARS_FILE'"
    exit 2
fi

# Get CLI program for running containers. Prefers podman if available,
# defaults to docker otherwise. Helpful for running script on workstations.
function get_container_cli() {
    if hash podman > /dev/null 2>&1 ; then
        echo "podman"
    else
        echo "docker"
    fi
}

function create_genesis() {
    # Use fresh working directory. The dirpath is used within the helm chart,
    # to read local files generated by "testnet generate", and push them
    # into the cluster config.
    test -d "$WORKDIR" && rm -r "$WORKDIR"
    mkdir -p "$WORKDIR"

    for i in $(seq "$NVALS"); do
        I="$((i-1))"
        NODEDIR="node${I}"
        mkdir -p "${WORKDIR}/${NODEDIR}"
        # This will be overwritten by pd testnet generate.
        echo '{"identity_key": "penumbravalid1lr73zgd726gpk7rl45hvpg9f7r9wchgg8gpjhx2gqntx4md6gg9sser05u","consensus_key": "9OQ8HOy4YsryEPLbTtPKoKdmmjSqEJhzvS+x0WC8YoM=","name": "","website": "","description": "","enabled": false,"funding_streams": [{"address": "penumbrav2t1wz70yfqlgzfgwml5ne04vhnhahg8axmaupuv7x0gpuzesfhhz63y52cqffv93k7qvuuq6yqtgcj0z267v59qxpjuvc0hvfaynaaemgmqzyj38xhj8yjx7vcftnyq9q28exjrdj","rate_bps": 100}],"sequence_number": 0,"governance_key": "penumbragovern1lr73zgd726gpk7rl45hvpg9f7r9wchgg8gpjhx2gqntx4md6gg9sthagp6"}' > "${WORKDIR}/${NODEDIR}/val.json"
    done

    find "$WORKDIR" -name "val.json" -exec cat {} + | jq -s > "${WORKDIR}/vals.json"

    # For the weekly testnets, we pass `--preserve-chain-id` when generating
    # the config. For testnet-preview, we don't want that option: we want
    # a unique chain id for every deploy.
    if [[ "$HELM_RELEASE" =~ ^penumbra-testnet$ ]] ; then
        preserve_chain_opt="--preserve-chain-id"
    else
        preserve_chain_opt=""
    fi
    echo "Generating new testnet files..."
    container_cli="$(get_container_cli)"
    # Silence shellcheck warning on 'preserve_chain_opt' being an empty string.
    # shellcheck disable=SC2086
    "$container_cli" run --user 0:0 \
        --pull always \
        -v "${WORKDIR}:${CONTAINERHOME}" --rm \
        --entrypoint pd \
        "${IMAGE}:${PENUMBRA_VERSION}" \
        testnet generate \
        $preserve_chain_opt \
        --validators-input-file "${CONTAINERHOME}/vals.json" > /dev/null

    # Clear out persistent peers. Will peer after services are bootstrapped.
    # The Helm chart requires that these local flat files exist, but we cannot
    # populate them with external IPs just yet. Make sure they're present,
    # but empty, for now.
    for i in $(seq 0 $((NVALS -1))); do
        echo > "${WORKDIR}/external_address_val_${i}.txt"
        echo > "${WORKDIR}/persistent_peers_val_${i}.txt"
    done
    for i in $(seq 0 $((NFULLNODES -1))); do
        echo > "${WORKDIR}/external_address_fn_${i}.txt"
        echo > "${WORKDIR}/persistent_peers_fn_${i}.txt"
    done
}

# Remove existing deployment and associated storage. Intended to omit removal
# of certain durable resources, such as LoadBalancer and ManagedCertificate.
# We intentionally don't use "helm uninstall" because GCP takes a while
# to propagate ingress recreation, causing delays in endpoint availability.
function helm_uninstall() {
    # Delete existing deployments.
    kubectl delete deployments -l app.kubernetes.io/instance="$HELM_RELEASE" --wait=false > /dev/null 2>&1
    # Delete all existing PVCs so that fresh testnet is created.
    kubectl delete pvc -l app.kubernetes.io/instance="$HELM_RELEASE" > /dev/null 2>&1
}

# Apply the Helm configuration to the cluster. Will overwrite resources
# as necessary. Will *not* replace certain durable resources like
# the ManagedCertificate, which is annotated with helm.sh/resource-policy=keep.
function helm_install() {
    helm upgrade --install "$HELM_RELEASE" ./charts/penumbra \
        --set "numValidators=$NVALS" \
        --set "numFullNodes=$NFULLNODES" \
        --set "penumbra.image=$IMAGE" \
        --set "penumbra.version=$PENUMBRA_VERSION" \
        --set "grafana.version=$PENUMBRA_VERSION" \
        --set "penumbra.uidGid=$PENUMBRA_UID_GID" \
        --set "tendermint.version=$TENDERMINT_VERSION" \
        --values "$HELM_VARS_FILE"
}

# Block until the Services' ExternalIP attributes are populated.
function wait_for_external_ips() {
    while true; do
      echo "Waiting for load balancer external IPs to be provisioned..."
      mapfile -t STATUSES < <(kubectl get svc -l app.kubernetes.io/instance="$HELM_RELEASE" --no-headers | grep p2p | awk '{print $4}')
      FOUND_PENDING=false
      for STATUS in "${STATUSES[@]}"; do
        if [[ "$STATUS" == "<pending>" ]]; then
          sleep 5
          FOUND_PENDING=true
          break
        fi
      done
      if [[ "$FOUND_PENDING" == "false" ]]; then
        break
      fi
    done
}

function wait_for_pods_to_be_running() {
    echo "Waiting for pods to be running..."
    kubectl wait --for=condition=ready pods --timeout=5m \
        -l app.kubernetes.io/instance="$HELM_RELEASE"
}

function collect_local_config_values() {
    for i in $(seq 0 $((NVALS - 1))); do
      echo "Getting public peer string for validator $i"
      NODE_ID="$(kubectl exec "$(kubectl get pods -l app.kubernetes.io/instance="$HELM_RELEASE" -o name | grep "penumbra.*val-${i}")" -c tm -- tendermint --home=/home/.tendermint show-node-id | tr -d '\r')"
      IP="$(kubectl get svc "${HELM_RELEASE}-p2p-val-${i}" -o json | jq -r .status.loadBalancer.ingress[0].ip | tr -d '\r')"
      EXTERNAL_ADDR="${IP}:26656"
      NODE_ADDR="${NODE_ID}@${EXTERNAL_ADDR}"
      echo "$EXTERNAL_ADDR" > "${WORKDIR}/external_address_val_${i}.txt"
      echo "$NODE_ADDR" > "${WORKDIR}/node_address_val_${i}.txt"
    done

    for i in $(seq 0 $((NFULLNODES - 1))); do
      echo "Getting public peer string for fullnode $i"
      NODE_ID="$(kubectl exec "$(kubectl get pods -l app.kubernetes.io/instance="$HELM_RELEASE" -o name | grep "penumbra.*-fn-${i}")" -c tm -- tendermint --home=/home/.tendermint show-node-id | tr -d '\r')"
      IP="$(kubectl get svc "${HELM_RELEASE}-p2p-fn-${i}" -o json | jq -r .status.loadBalancer.ingress[0].ip | tr -d '\r')"
      EXTERNAL_ADDR="${IP}:26656"
      NODE_ADDR="${NODE_ID}@${EXTERNAL_ADDR}"
      echo "$EXTERNAL_ADDR" > "${WORKDIR}/external_address_fn_${i}.txt"
      echo "$NODE_ADDR" > "${WORKDIR}/node_address_fn_${i}.txt"
    done

    # Now we've got all the info we need in local flat files: node ids, external ips,
    # tied to designation as a service/pod identity. Let's loop over those local files
    # and assemble the info into tm config attributes for each service.
    for i in $(seq 0 $((NVALS - 1))); do
        find "$WORKDIR" -type f -iname 'node_address*' -and -not -iname "*val_${i}.txt" -exec cat {} + \
            | perl -npE 's/\n/,/g' | perl -npE 's/,$//' \
            > "${WORKDIR}/persistent_peers_val_${i}.txt"
    done
    for i in $(seq 0 $((NFULLNODES - 1))); do
        find "$WORKDIR" -type f -iname 'node_address*' -and -not -iname "*fn_${i}.txt" -exec cat {} + \
            | perl -npE 's/\n/,/g' | perl -npE 's/,$//' \
            > "${WORKDIR}/persistent_peers_fn_${i}.txt"
    done
}

# Deploy a fresh testnet, destroying all prior chain state with new genesis.
function full_ci_rebuild() {
    echo "Shutting down existing testnet if necessary..."
    helm_uninstall

    echo "Creating new genesis config..."
    create_genesis

    echo "Performining initial deploy of network, with private IPs..."
    # Will deploy nodes, but will not be able to peer. Need to get IPs of services, then can peer
    helm_install

    wait_for_external_ips

    wait_for_pods_to_be_running

    echo "Collecting config values for each node..."
    collect_local_config_values

    echo "Applying fresh values so that nodes can peer and advertise external addresses."
    # First, remove the old resources.
    helm_uninstall
    sleep 5
    helm_install

    # Report results
    if wait_for_pods_to_be_running ; then
        echo "Deploy complete!"
    else
        echo "ERROR: pods failed to enter running start. Deploy has failed."
        return 1
    fi
}

# Determine whether the version to be deployed constitutes a semver "patch" release,
# e.g. 0.1.2 -> 0.1.3.
function is_patch_release() {
    # Ensure version format is semver, otherwise fail.
    if ! grep -qP '^v[\d\.]+' <<< "$PENUMBRA_VERSION" ; then
        return 1
    fi
    # Split on '.', inspect final field.
    z="$(perl -F'\.' -lanE 'print $F[-1]' <<< "$PENUMBRA_VERSION")"
    # If "z" in x.y.z is 0, then it's a minor release. (Or a major release,
    # but we don't need to worry about that yet.)
    if [[ $z = "0" ]] ; then
        return 2
    else
        return 0
    fi
}

# Bump the version of pd running for the deployment, across all
# fullnodes and validators. Allow the cluster to reconcile the changes
# by terminating and creating pods to match. Does *not* alter chain state.
# Allows us to handle "patch" versions.
function update_image_for_running_deployment() {
    kubectl set image deployments \
        -l "app.kubernetes.io/instance=${HELM_RELEASE}, app.kubernetes.io/component in (fullnode, validator)" \
        "pd=${IMAGE}:${PENUMBRA_VERSION}"
    # Wait for rollout to complete. Will block until pods are marked Ready.
    kubectl rollout status deployment \
        -l "app.kubernetes.io/instance=${HELM_RELEASE}, app.kubernetes.io/component in (fullnode, validator)"
}

function main() {
    if is_patch_release ; then
        echo "Release target '$PENUMBRA_VERSION' is a patch release; will preserve testnet while bumping version."
        update_image_for_running_deployment
    else
        echo "Release target '$PENUMBRA_VERSION' requires a full re-deploy; will generate new testnet chain info."
        full_ci_rebuild
    fi
}

main
