# Target C — Helm chart

**Arrives in milestone M2.5** (after Terraform). Chart `k8s/helm/n8n-kit`: Deployments for main / webhook / worker with `n8nio/runners` as in-pod sidecars, Valkey StatefulSet, CloudNativePG cluster or an external database, Ingress + cert-manager, KEDA scaling workers on queue depth. `helm lint` + `helm template` snapshots and a kind install in CI.
