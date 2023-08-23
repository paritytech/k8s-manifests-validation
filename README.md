A script for validating Kubernetes YAML manifests against OPA policies and JSON schema.

Multiple tools ([Gatekeeper](https://open-policy-agent.github.io/gatekeeper/website/), [Datree](https://github.com/datreeio/datree)) are packed into the script that can be run against a directory with Helm chart values. The script renders chart values as K8s YAML manifests, checks against configured Gatekeeper policies (stored as code), and verifies it conform with K8s JSON schema.

## Quick start
```
./validate-k8s-manifests.sh manifests
```

Run `validate-k8s-manifests.sh` to see the available input arguments.

## Docker
The script can be run as Docker image:
```
docker run --rm -it -v "$(pwd):/git" docker.io/paritytech/kube-manifests-validation:latest manifests
```

## Directory layout
The script expects a very specific directory layout with Helm chart values. `manifests` is a directory that can be passed as the first argument to the script.
```
manifests
└── my-app
    ├── Chart.yaml
    ├── values-dev.yaml
    ├── values-prod.yaml
    ├── values-staging.yaml
    └── values.yaml
```

`Chart.yaml` is the umbrella chart that wraps the upstream chart as a dependency. It may look the following:
```yaml
apiVersion: v2
name: my-app
description: A Helm chart for Kubernetes
type: application
version: 0.1.0
dependencies:
- name: upstream-chart
  version: "2.0.0"
  repository: "https://upstream-repo.github.io/upstream-chart"
```
