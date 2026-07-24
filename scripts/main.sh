#!/usr/bin/env bash

set -eEuo pipefail

# Trap -e errors
trap 'echo "Exit status $? at line $LINENO from: $BASH_COMMAND"' ERR

if [[ -n ${RUNNER_DEBUG:-} ]]; then
    set -x
fi

wait_for_kind() {
    echo "Waiting for KinD cluster to be ready..."

    kubectl wait --namespace kube-system \
        --for=condition=ready \
        pod --all \
        --timeout=90s

    echo "KinD cluster is ready!"

    kubectl cluster-info
    kubectl get pods -n kube-system

}

export_housekeeping_key() {
    kubectl get secrets -n "$ASTARTE_NAMESPACE" astarte-housekeeping-private-key -o 'jsonpath={.data.private-key}' |
        base64 -d >"$HOUSEKEEPING_KEY"

    {
        echo "housekeeping-key<<EOF"
        cat "$HOUSEKEEPING_KEY"
        echo 'EOF'
    } >>"$GITHUB_OUTPUT"
}

wait_for_astarte() {
    echo "Waiting for Astarte API to be ready..."
    for _ in {1..6}; do
        if [[ -n $(astartectl housekeeping realms list --ignore-ssl-errors -u https://api.autotest.astarte-platform.org -k "$HOUSEKEEPING_KEY") ]]; then
            echo "astartectl is able to connect to the Astarte API"
            return
        else
            sleep 5
        fi
    done

    echo "astartectl failed to connect to the Astarte API"
    exit 1
}

wait_for_astarte_realm() {
    for _ in {1..6}; do
        if [[ -n $(astartectl housekeeping realms show "$ASTARTE_REALM" --ignore-ssl-errors -u https://api.autotest.astarte-platform.org -k "$HOUSEKEEPING_KEY") ]]; then
            echo "Astarte Realm created successfully"
            return
        else
            sleep 5
        fi
    done

    echo "Astarte Realm creation timed out"
    exit 1
}

create_astarte_realm() {
    if [[ -z ${ASTARTE_REALM:-} ]]; then
        echo "Astarte realm is empty, skipping creation"
        return
    fi

    export REALM_PRIVATE_KEY="$ACTION_PATH/${ASTARTE_REALM}_private.pem"
    export REALM_PUBLIC_KEY="$ACTION_PATH/${ASTARTE_REALM}_public.pem"

    astartectl utils gen-keypair "$ASTARTE_REALM"

    # export realm-key output
    cat "$REALM_PRIVATE_KEY"
    {
        echo 'realm-key<<EOF'
        cat "$REALM_PRIVATE_KEY"
        echo 'EOF'
    } >>"$GITHUB_OUTPUT"

    astartectl housekeeping realms create --ignore-ssl-errors -y "$ASTARTE_REALM" \
        -u https://api.autotest.astarte-platform.org \
        --realm-public-key "$REALM_PUBLIC_KEY" \
        -k "$HOUSEKEEPING_KEY"

    wait_for_astarte_realm

    mkdir -p ~/.config/astarte

    echo 'context: ""' >>~/.config/astarte/astartectl.yaml

    astartectl config clusters create "$CLUSTER_NAME" \
        --api-url https://api.autotest.astarte-platform.org \
        --housekeeping-key "$HOUSEKEEPING_KEY"

    astartectl config contexts create "$CONTEXT_NAME" \
        --cluster "$CLUSTER_NAME" \
        --realm-name "$ASTARTE_REALM" \
        --realm-private-key "$REALM_PRIVATE_KEY"

    astartectl config contexts update "$CONTEXT_NAME" --activate
}

cd "$ACTION_PATH"
echo "::group::Ensure KinD is up"
wait_for_kind
echo "::endgroup::"

CLUSTER_NAME="$(kubectl config current-context)"
export CLUSTER_NAME
export CONTEXT_NAME=$CLUSTER_NAME
export HOUSEKEEPING_KEY="$ACTION_PATH/housekeeping_key.pem"

echo "::group::Setup Astarte Kubernetes namespace"
kubectl create namespace "$ASTARTE_NAMESPACE"
echo "::endgroup::"

echo "::group::Install prerequisites"
. ./scripts/install-prerequisites.sh
echo "::endgroup::"

echo "::group::Install Astarte Operator"
. ./scripts/install-operator.sh
echo "::endgroup::"

echo "::group::Setup SSL Certificates"
. ./scripts/setup-ssl.sh
echo "::endgroup::"

echo "::group::Setup Astarte"
. ./scripts/setup-astarte.sh
echo "::endgroup::"

# Needed before wait for astarte
echo "::group::Export housekeeping key"
export_housekeeping_key
echo "::endgroup::"

echo "::group::Wait for Astarte"
wait_for_astarte
echo "::endgroup::"

echo "::group::Create realm"
create_astarte_realm
echo "::endgroup::"
