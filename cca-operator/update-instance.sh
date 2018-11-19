#!/usr/bin/env bash

[ "${1}" == "--help" ] && echo ./update-instance.sh '<INSTANCE_ID>' && exit 0

source functions.sh
! cluster_management_init "${1}" && exit 1

! [ -e "${CKAN_VALUES_FILE}" ] && echo missing ${CKAN_VALUES_FILE} && exit 1

echo Creating instance: ${INSTANCE_ID}

INSTANCE_DOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("domain", ""))
'`

CKAN_ADMIN_EMAIL=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanAdminEmail", "admin@${INSTANCE_ID}"))
'`

WITH_SANS_SSL=`python3 -c '
import yaml;
print("1" if yaml.load(open("'${CKAN_VALUES_FILE}'")).get("withSansSSL", False) else "0")
'`

REGISTER_SUBDOMAIN=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("registerSubdomain", ""))
'`

CKAN_HELM_CHART_REPO=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanHelmChartRepo", "https://raw.githubusercontent.com/ViderumGlobal/ckan-cloud-helm/master/charts_repository"))
'`

CKAN_HELM_CHART_VERSION=`python3 -c '
import yaml;
print(yaml.load(open("'${CKAN_VALUES_FILE}'")).get("ckanHelmChartVersion", ""))
'`

LOAD_BALANCER_HOSTNAME=$(kubectl -n default get service traefik -o yaml \
    | python3 -c 'import sys, yaml; print(yaml.load(sys.stdin)["status"]["loadBalancer"]["ingress"][0]["hostname"])' 2>/dev/null)

if [ "${REGISTER_SUBDOMAIN}" != "" ]; then
    cluster_register_sub_domain "${REGISTER_SUBDOMAIN}" "${LOAD_BALANCER_HOSTNAME}"
    [ "$?" != "0" ] && exit 1
fi

if ! [ -z "${INSTANCE_DOMAIN}" ]; then
    if grep 'rule = "Host:'${INSTANCE_DOMAIN}'"' /etc/ckan-cloud/traefik-values.yaml; then
        echo Skipping load balancer deployment
        echo instance domain already exists in load balancer values: ${INSTANCE_DOMAIN}
    else
        echo Configuring load balancer for domain "${INSTANCE_DOMAIN}"
        cp -f "${TRAEFIK_VALUES_FILE}" /etc/ckan-cloud/backups/traefik-values.yaml.`date +%Y-%m-%d_%H-%M` &&\
        cp -f "${TRAEFIK_VALUES_FILE}" /etc/ckan-cloud/backups/traefik-values.yaml.last
        [ "$?" != "0" ] && exit 1

        TRAEFIK_VALUES_MODIFIED_FILE=/etc/ckan-cloud/traefik-values.yaml

        if [ "${WITH_SANS_SSL}" == "1" ]; then
            echo Configuring SSL
            TEMPFILE=`mktemp`
            python3 -c '
        import yaml, json;
        traefik_values = yaml.load(open("'${TRAEFIK_VALUES_MODIFIED_FILE}'"));
        def acme_domains():
            for line in traefik_values["acmeDomains"].splitlines():
                if line.startswith("  sans = ["):
                    line = "  sans = " + json.dumps(json.loads(line.strip().split(" = ")[1]) + ["'${INSTANCE_DOMAIN}'"])
                yield line
        print(yaml.dump(dict(traefik_values, acmeDomains="\n".join(acme_domains())),
                        default_flow_style=False));
        ' > $TEMPFILE
            [ "$?" != "0" ] && exit 1
            TRAEFIK_VALUES_MODIFIED_FILE=$TEMPFILE
        fi

        TEMPFILE=`mktemp`
        python3 -c '
        import yaml;
        traefik_values = yaml.load(open("'${TRAEFIK_VALUES_MODIFIED_FILE}'"));
        traefik_values["backends"] += " \n\
        [backends.'${INSTANCE_ID}'] \n\
          [backends.'${INSTANCE_ID}'.servers.server1] \n\
            url = \"http://nginx.'${INSTANCE_NAMESPACE}'\" \n\
        ";
        traefik_values["frontends"] += " \n\
        [frontends.'${INSTANCE_ID}'] \n\
          backend=\"'${INSTANCE_ID}'\" \n\
          passHostHeader = true \n\
          [frontends.'${INSTANCE_ID}'.headers] \n\
            SSLRedirect = true \n\
          [frontends.'${INSTANCE_ID}'.routes.route1] \n\
            rule = \"Host:'${INSTANCE_DOMAIN}'\" \n\
        ";
        print(yaml.dump(traefik_values, default_flow_style=False));
        ' > $TEMPFILE
        [ "$?" != "0" ] && exit 1
        TRAEFIK_VALUES_MODIFIED_FILE=$TEMPFILE

        mv $TRAEFIK_VALUES_MODIFIED_FILE $TRAEFIK_VALUES_FILE

        echo Deploying to kube context `kubectl config current-context`, load balancer hostname: ${LOAD_BALANCER_HOSTNAME}

        helm upgrade "${TRAEFIK_HELM_RELEASE_NAME}" "${TRAEFIK_HELM_CHART_PATH}" \
            --namespace "${TRAEFIK_NAMESPACE}" -if "${TRAEFIK_VALUES_FILE}" --dry-run --debug > /dev/stderr &&\
        helm upgrade "${TRAEFIK_HELM_RELEASE_NAME}" "${TRAEFIK_HELM_CHART_PATH}" \
            --namespace "${TRAEFIK_NAMESPACE}" -if "${TRAEFIK_VALUES_FILE}"
        [ "$?" != "0" ] && exit 1
    fi
fi

if kubectl get ns "${INSTANCE_NAMESPACE}"; then
    IS_NEW_NAMESPACE=0
    echo Namespace exists: ${INSTANCE_NAMESPACE}
    echo skipping RBAC creation
else
    IS_NEW_NAMESPACE=1
    echo Creating namespace: ${INSTANCE_NAMESPACE}

    kubectl create ns "${INSTANCE_NAMESPACE}" &&\
    kubectl --namespace "${INSTANCE_NAMESPACE}" \
        create serviceaccount "ckan-${INSTANCE_NAMESPACE}-operator" &&\
    kubectl --namespace "${INSTANCE_NAMESPACE}" \
        create role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                    --verb list,get,create \
                    --resource secrets,pods,pods/exec,pods/portforward &&\
    kubectl --namespace "${INSTANCE_NAMESPACE}" \
        create rolebinding "ckan-${INSTANCE_NAMESPACE}-operator-rolebinding" \
                           --role "ckan-${INSTANCE_NAMESPACE}-operator-role" \
                           --serviceaccount "${INSTANCE_NAMESPACE}:ckan-${INSTANCE_NAMESPACE}-operator"
    [ "$?" != "0" ] && exit 1
fi

echo Deploying CKAN instance: ${INSTSANCE_ID}

echo Initializing ckan-cloud Helm repo "${CKAN_HELM_CHART_REPO}"
helm init --client-only &&\
helm repo add ckan-cloud "${CKAN_HELM_CHART_REPO}"
[ "$?" != "0" ] && exit 1

helm_upgrade() {
    if [ -z "${CKAN_HELM_CHART_VERSION}" ]; then
        echo Using latest stable ckan chart
        VERSIONARGS=""
    else
        echo Using ckan chart version ${CKAN_HELM_CHART_VERSION}
        VERSIONARGS=" --version ${CKAN_HELM_CHART_VERSION} "
    fi
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" ckan-cloud/ckan \
        -if "${CKAN_VALUES_FILE}" "$@" --dry-run --debug > /dev/stderr $VERSIONARGS &&\
    helm --namespace "${INSTANCE_NAMESPACE}" upgrade "${CKAN_HELM_RELEASE_NAME}" ckan-cloud/ckan \
        -if "${CKAN_VALUES_FILE}" $VERSIONARGS "$@"
}

wait_for_pods() {
    DELAY_SECONDS=10
    TOTAL_SECONDS=0
    while ! kubectl --namespace "${INSTANCE_NAMESPACE}" get pods -o yaml | python3 -c '
import yaml, sys;
for pod in yaml.load(sys.stdin)["items"]:
    if pod["status"]["phase"] != "Running":
        print(pod["metadata"]["name"] + ": " + pod["status"]["phase"])
        exit(1)
    elif not pod["status"]["containerStatuses"][0]["ready"]:
        print(pod["metadata"]["name"] + ": ckan container is not ready")
        exit(1)
exit(0)
    '; do
        kubectl --namespace "${INSTANCE_NAMESPACE}" get pods
        sleep $DELAY_SECONDS
        TOTAL_SECONDS=$(expr $TOTAL_SECONDS + $DELAY_SECONDS)
        echo "...${TOTAL_SECONDS}s"
        # if [ "$(expr $TOTAL_SECONDS > 180)" == "1" ]; then
        #     echo "Waiting too long, deleting and redeploying ckan and jobs deployments"
        #     kubectl delete deployment ckan jobs
        #     ! helm_upgrade && return 1
        # fi
    done &&\
    kubectl --namespace "${INSTANCE_NAMESPACE}" get pods
}

if [ "${IS_NEW_NAMESPACE}" == "1" ]; then
    helm_upgrade --set replicas=1 --set nginxReplicas=1 &&\
    sleep 2 &&\
    wait_for_pods
    [ "$?" != "0" ] && exit 1
fi

helm_upgrade &&\
sleep 1 &&\
wait_for_pods
[ "$?" != "0" ] && exit 1

CKAN_POD_NAME=$(kubectl -n ${INSTANCE_NAMESPACE} get pods -l "app=ckan" -o 'jsonpath={.items[0].metadata.name}')
echo CKAN_POD_NAME = "${CKAN_POD_NAME}" > /dev/stderr

if kubectl -n ${INSTANCE_NAMESPACE} exec -it ${CKAN_POD_NAME} -- bash -c \
    "ckan-paster --plugin=ckan sysadmin -c /etc/ckan/production.ini list" \
        | grep "name=admin"
then
    CKAN_ADMIN_PASSWORD=$( \
        get_secret_from_json "$(kubectl -n "${INSTANCE_NAMESPACE}" get secret ckan-admin-password -o json)" \
        "CKAN_ADMIN_PASSWORD" \
    )
    echo admin user already exists
else
    CKAN_ADMIN_PASSWORD=$(python3 -c "import binascii,os;print(binascii.hexlify(os.urandom(12)).decode())")
    ! kubectl -n "${INSTANCE_NAMESPACE}" create secret generic ckan-admin-password "--from-literal=CKAN_ADMIN_PASSWORD=${CKAN_ADMIN_PASSWORD}" && exit 1
    echo y \
        | kubectl -n ${INSTANCE_NAMESPACE} exec -it ${CKAN_POD_NAME} -- bash -c \
            "ckan-paster --plugin=ckan sysadmin -c /etc/ckan/production.ini add admin password=${CKAN_ADMIN_PASSWORD} email=${CKAN_ADMIN_EMAIL}" \
                > /dev/stderr
    [ "$?" != "0" ] && exit 1
fi

if ! [ -z "${INSTANCE_DOMAIN}" ]; then
    echo Running sanity tests for CKAN instance ${INSTSANCE_ID} on domain ${INSTANCE_DOMAIN}
    if [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]; then
        kubectl -n default patch deployment traefik \
            -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"date\":\"`date +'%s'`\"}}}}}" &&\
        kubectl -n default rollout status deployment traefik &&\
        sleep 10 &&\
        [ "$(curl https://${INSTANCE_DOMAIN}/api/3)" != '{"version": 3}' ]
        [ "$?" != "0" ] && exit 1
    fi
fi

echo Great Success!
echo CKAN Instance ${INSTANCE_ID} is ready
instance_connection_info "${INSTANCE_ID}" "${INSTANCE_NAMESPACE}" "${INSTANCE_DOMAIN}" "${CKAN_ADMIN_PASSWORD}"

exit 0
