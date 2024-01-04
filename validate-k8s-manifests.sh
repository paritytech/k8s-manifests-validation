#!/usr/bin/env bash
set -eu -o pipefail

cleanup() {
  rm -rf $TMP_DIR
}

trap 'cleanup' EXIT
# shellcheck disable=SC2155
export TMP_DIR=$(mktemp -d)

usage() {
  echo "$(basename "$0") [--longoption ...] [KUBERNETES_MANIFESTS_PATH]
  Validate Kubernetes manifests using Gator and Datree CLI utilities

  Flags:
    --parallel Number of parallel jobs to validate manifests (default: 10)
    --gatekeeper-policies-dir Directory where Gatekeeper policies are stored (YAML) (default: KUBERNETES_MANIFESTS_PATH/gatekeeper-policies)
    --k8s-schema-version Version of Kubernetes schema to use for manifests validation (default: 1.25.9)
    --k8s-schema-dir Directory where Kubernetes schema is stored (default: /schemas/k8s)
    --k8s-crds-dir Directory where Kubernetes CRD schemas are stored (default: /schemas/crds)
    --datree-policy-config Path to Datree configuration file (default: ./datree-policies.yaml)
    --helm-registry-config Path to Helm registry config file (default: ~/.config/helm/registry/config.json)
    --exclude-dirs-regex Regex (grep -E) to exclude directories from validation (default: '(gatekeeper-policies|00-meta-app)')
    --policiy-violation-enforcement Defines if script should exit with an error if Gatekeeper policies are violated or just with the warning and exit code 0. Possible values: (warn|deny) (default: deny)
    --git-ref-changed-paths A Git ref for comparing HEAD to identify which files have changed
    --skip-gatekeeper Skip Gatekeeper policy validation"
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --parallel) parallel="$2"; shift ;;
    --exclude-dirs-regex) exclude_dirs_regex="$2"; shift ;;
    --gatekeeper-policies-dir) gatekeeper_policies_dir="$2"; shift ;;
    --k8s-schema-version) k8s_schema_version="$2"; shift ;;
    --k8s-schema-dir) k8s_schema_dir="$2"; shift ;;
    --k8s-crds-dir) k8s_crds_dir="$2"; shift ;;
    --datree-policy-config) datree_policy_config="$2"; shift ;;
    --helm-registry-config) helm_registry_config="$2"; shift ;;
    --policiy-violation-enforcement) policiy_violation_enforcement="$2"; shift ;;
    --git-ref-changed-paths) git_ref_changed_paths="$2"; shift ;;
    --skip-gatekeeper) skip_gatekeeper="true"; shift 0 ;;
    *) manifests="$1"; ;;
  esac
  shift
done

if [[ -z ${manifests+x} ]]; then
  usage
  exit 1
fi

EXIT_CODE=0
K8S_MANIFESTS_DIR="$manifests"
GATEKEEPER_POLICIES_DIR="${gatekeeper_policies_dir:-$K8S_MANIFESTS_DIR/gatekeeper-policies}"
EXCLUDE_DIRS_REGEX="${exclude_dirs_regex:-(gatekeeper-policies|00-meta-app)}"
PARALLEL_MANIFEST_VALIDATIONS="${parallel:-10}"
HELM_REGISTRY_CONFIG="$([[ -n ${helm_registry_config:-} ]] && printf -- '--registry-config %s' $helm_registry_config || true)"
POLICIY_VIOLATION_ENFORCEMENT="${policiy_violation_enforcement:-deny}"
GIT_REF_CHANGED_PATHS="${git_ref_changed_paths:-master}"
export SKIP_GATEKEEPER="${skip_gatekeeper:-false}"
export K8S_SCHEMA_VERSION="${k8s_schema_version:-1.25.9}"
export K8S_SCHEMA_DIR="${k8s_schema_dir:-/schemas/k8s}"
export K8S_CRDS_DIR="${k8s_crds_dir:-/schemas/crds}"
export DATREE_POLICY_CONFIG="${datree_policy_config:-datree-policies.yaml}"

if [[ $SKIP_GATEKEEPER == "true" ]]; then
  echo "Skipping Gatekeeper policy validation"
else
  # In case lock file (Chart.lock) is out of sync with the dependencies file (Chart.yaml)
  helm dependency build $GATEKEEPER_POLICIES_DIR || helm dependency update $GATEKEEPER_POLICIES_DIR
  mkdir -p "$TMP_DIR/gatekeeper"
  helm template -n default -f $GATEKEEPER_POLICIES_DIR/values.yaml $GATEKEEPER_POLICIES_DIR \
    --set "expansionTemplate.enabled=true" \
    --set "defaultPolicies.constraints.defaultEnforcementAction=$POLICIY_VIOLATION_ENFORCEMENT" > $TMP_DIR/gatekeeper/policies.yaml
fi

validate_manifests() {
  local values_path=$1
  local dir_name=$2
  local exit_code=0

  echo -e "\nChecking chart with values file $values_path"
  CHART_TEMPLATE="$(helm template -n default -f $dir_name/values.yaml -f $values_path $dir_name)"

  if [[ $SKIP_GATEKEEPER == "false" ]]; then
    # gator policy check
    echo "Checking Gatekeeper policy violations"
    set +e
    (echo "$CHART_TEMPLATE" | gator test -f $TMP_DIR/gatekeeper/policies.yaml)
    if [[ $? -gt 0 ]]; then
      exit_code=1
    fi
    set -e
  fi

  # datree linting
  echo "Linting Chart template"
  set +e
  (echo "$CHART_TEMPLATE" | datree test --policy-config $DATREE_POLICY_CONFIG \
    --verbose --no-record --only-k8s-files --schema-version $K8S_SCHEMA_VERSION --ignore-missing-schemas \
    --schema-location $K8S_SCHEMA_DIR \
    --schema-location "$K8S_CRDS_DIR/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" -)
  if [[ $? -gt 0 ]]; then
    exit_code=1
  fi
  set -e

  return $exit_code
}

export -f validate_manifests

set +o pipefail # mask grep failing on empty input
CHANGED_GIT_PATHS=$(git diff --name-only $GIT_REF_CHANGED_PATHS... --diff-filter=d | grep -E "^$K8S_MANIFESTS_DIR/" | grep -vE $EXCLUDE_DIRS_REGEX | cut -d '/' -f1,2 | sort -u)
set +o pipefail

if [[ -n $CHANGED_GIT_PATHS ]]; then
  CHANGED_CHARTS_PATHS=$(find $CHANGED_GIT_PATHS -name Chart.yaml)
else
  echo "No charts changed in '$K8S_MANIFESTS_DIR'. Nothing to do here."
  exit 0
fi

# Generate stub Chart.yaml to collect dependencies from all Chart.yaml files we will be checking
# It allows to run `helm repo update` just once instead of for every changed chart
mkdir -p "$TMP_DIR/stub-chart"
STUB_CHART=$(cat <<EOF
apiVersion: v2
name: stub-chart
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
dependencies:
EOF
)
echo "$STUB_CHART" > $TMP_DIR/stub-chart/Chart.yaml

for path in $CHANGED_CHARTS_PATHS; do
  DIR_NAME=$(dirname $path)
  if find $DIR_NAME -name 'Chart.yaml' > /dev/null; then
    # collect all chart dependencies into one stub Chart.yaml
    yq --indent 0 'select(.dependencies!=null) | .dependencies | map(select(.repository|match("^http(s)?://"))) | select(length>0)' "$DIR_NAME/Chart.yaml" >> $TMP_DIR/stub-chart/Chart.yaml
  fi
done
yq --indent 0 '.dependencies | map(["helm", "repo", "add", .name, .repository] | join(" ")) | .[]' $TMP_DIR/stub-chart/Chart.yaml | bash --
if [[ -n $(helm repo list -o yaml | yq -r '.[]') ]]; then
  helm repo update
fi

# Validate manifests
for path in $CHANGED_CHARTS_PATHS; do
  DIR_NAME=$(dirname $path)
  # Check if candidate path has `values.yaml` file. It is indicative of the Helm chart directory.
  if find $DIR_NAME -name 'values.yaml' > /dev/null; then
    CHART_VALUES_PATHS=$(find $DIR_NAME -name 'values-*.yaml')
    helm $HELM_REGISTRY_CONFIG dependency build --skip-refresh $DIR_NAME || helm $HELM_REGISTRY_CONFIG dependency update --skip-refresh $DIR_NAME
    set +e
    echo "$CHART_VALUES_PATHS" | xargs -P$PARALLEL_MANIFEST_VALIDATIONS -I {} bash -c 'set -eu -o pipefail; validate_manifests "$@" | sponge' _ {} $DIR_NAME
    EXIT_CODE=$?
    set -e
    if [[ $EXIT_CODE -eq 123 ]]; then # invocation of the command inside `xargs` exited with status 1-125
      EXIT_CODE=1
    elif [[ $EXIT_CODE -gt 0 ]]; then
      echo "❌ An error occured while executing manifests validation. This is all we know. Exitting early..."
      exit $EXIT_CODE
    fi
  fi
done

if [[ $EXIT_CODE -gt 0 ]]; then
  echo "❌ Errors occured during manifests validation. Exitting..."
  exit $EXIT_CODE
else
  echo "✅ Successfully validated all K8s manifests"
fi
