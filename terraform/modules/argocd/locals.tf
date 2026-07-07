locals {
  cluster_server = "https://kubernetes.default.svc"
  any_resource   = [{ group = "*", kind = "*" }]

  # AppProjects scope what each group of apps may pull and where it may deploy.
  # sourceRepos is pinned to our repo (NOT "*") so a compromised/typo'd repo URL
  # cannot be reconciled. destinations + resource whitelists are scoped per project
  # to the least privilege each actually needs.
  projects = {
    # Operators/CRDs/secrets/DB/policies: legitimately cluster-wide (installs CRDs,
    # ClusterRoles, ClusterPolicies, ClusterIssuer, ClusterSecretStore across many
    # namespaces), so it keeps the broad grant — documented, not accidental.
    platform = {
      description         = "Cluster platform: ArgoCD-managed operators, secrets, database, policies."
      destinations        = [{ server = local.cluster_server, namespace = "*" }]
      cluster_resources   = local.any_resource
      namespace_resources = local.any_resource
    }
    # Business microservices deploy ONLY namespaced workloads into the app namespace
    # — no cluster-scoped resources, no other namespaces. Least privilege: a
    # compromised app repo path cannot create ClusterRoles or touch kube-system.
    apps = {
      description         = "Business microservices (api-service, inventory-service)."
      destinations        = [{ server = local.cluster_server, namespace = var.app_namespace }]
      cluster_resources   = []
      namespace_resources = local.any_resource
    }
    # Observability needs cluster-scoped CRDs (prometheus-operator, trivy) + a few
    # namespaces (monitoring, the trivy operator ns, kube-system for the Traefik
    # metrics HelmChartConfig).
    monitoring = {
      description = "Observability stack: Prometheus, Grafana, Loki, exporters."
      destinations = [
        { server = local.cluster_server, namespace = "monitoring" },
        { server = local.cluster_server, namespace = "trivy-system" },
        { server = local.cluster_server, namespace = "kube-system" },
      ]
      cluster_resources   = local.any_resource
      namespace_resources = local.any_resource
    }
  }

  # The Argo CRDs (Application/AppProject) ship with the Helm release, so the raw
  # manifests below must apply only after it. gavinbunney/kubectl avoids the
  # plan-time CRD schema lookup that would otherwise fail on a first apply.
  argocd_api_version = "argoproj.io/v1alpha1"
}
