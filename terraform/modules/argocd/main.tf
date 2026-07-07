resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = var.common_labels
  }
}

resource "helm_release" "this" {
  name       = "argocd"
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_version

  # Fail the apply if the control plane does not become healthy.
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  # Server runs without its own TLS; TLS terminates at the ingress. dex is
  # disabled (no SSO in the sandbox) and the notifications/applicationset
  # controllers stay on so ApplicationSets and sync notifications work.
  values = [yamlencode({
    global = {
      # Keep the footprint small enough for the 8-12GB sandbox VM.
      logging = { format = "json" }
    }
    dex = { enabled = false }
    # UI reachable from the host without a port-forward: Traefik routes the
    # sslip.io hostname straight to the (insecure, HTTP) argocd-server. Gated on
    # server_insecure — a TLS-mode server needs passthrough, not this ingress.
    server = {
      ingress = {
        enabled          = var.ingress_host != "" && var.server_insecure
        ingressClassName = "traefik"
        hostname         = var.ingress_host
        # Auto-discovered tile on the platform portal (gitops/config/portal).
        annotations = {
          "gethomepage.dev/enabled"     = "true"
          "gethomepage.dev/name"        = "ArgoCD"
          "gethomepage.dev/group"       = "Platform"
          "gethomepage.dev/icon"        = "argocd.png"
          "gethomepage.dev/description" = "GitOps control plane"
        }
      }
      # Prometheus metrics Service for argocd-server.
      metrics = { enabled = true }
    }
    # Metrics Services for the other components. Enabling here creates the
    # Services only (no ServiceMonitor CRD needed at install time); the
    # ServiceMonitors that scrape them live in gitops/config/monitoring-config,
    # which syncs after prometheus-operator-crds so the CRD exists.
    controller     = { metrics = { enabled = true } }
    repoServer     = { metrics = { enabled = true } }
    applicationSet = { metrics = { enabled = true } }
    configs = {
      params = {
        "server.insecure" = var.server_insecure
        # ServerSideDiff: compute diffs via a server-side-apply dry-run so
        # apiserver defaulting and mutating-webhook/operator-injected fields
        # (CNPG Cluster defaults, Kyverno CRD/policy defaults, ESO strategy
        # fields) don't show as permanent false OutOfSync. This is the robust,
        # non-brittle alternative to enumerating ignored fields per resource.
        "controller.diff.server.side" = "true"
      }
      cm = {
        # Surface CNPG Cluster health in the ArgoCD UI.
        "resource.customizations.health.postgresql.cnpg.io_Cluster" = <<-EOT
          hs = {}
          if obj.status ~= nil and obj.status.phase ~= nil then
            if obj.status.phase == "Cluster in healthy state" then
              hs.status = "Healthy"
            else
              hs.status = "Progressing"
            end
            hs.message = obj.status.phase
            return hs
          end
          hs.status = "Progressing"
          hs.message = "Waiting for CNPG cluster status"
          return hs
        EOT

        # Ignore fields injected by mutating webhooks/operators so these apps
        # report Synced instead of permanent (benign) drift. The resources are
        # Healthy and functional; only git-vs-live equality is affected.
        # Kyverno's webhook defaults spec.admission/emitWarning and normalizes rules:
        "resource.customizations.ignoreDifferences.kyverno.io_ClusterPolicy" = yamlencode({
          jsonPointers = ["/spec/admission", "/spec/emitWarning", "/spec/rules"]
        })
        # ESO's webhook defaults per-remoteRef strategy fields:
        "resource.customizations.ignoreDifferences.external-secrets.io_ExternalSecret" = yamlencode({
          jqPathExpressions = [
            ".spec.data[]?.remoteRef.conversionStrategy",
            ".spec.data[]?.remoteRef.decodingStrategy",
            ".spec.data[]?.remoteRef.metadataPolicy",
          ]
        })
        # NOTE: the CNPG Cluster needs no per-resource ignore list — ServerSideDiff
        # (enabled above) makes the operator's ~15 defaulted spec fields diff clean,
        # so the Cluster reports Synced-and-Healthy without a brittle field
        # enumeration. Same for the Kyverno-managed CRDs' server-side schema/status
        # defaults. The customizations below are retained as defence-in-depth and to
        # keep diffs clean even if ServerSideDiff is toggled off.
        "resource.customizations.ignoreDifferences.apiextensions.k8s.io_CustomResourceDefinition" = yamlencode({
          jqPathExpressions = [".spec.versions[]?.schema.openAPIV3Schema"]
        })
      }
    }
  })]
}

# Repository credentials for the GitOps repo. Gated on a PLAN-KNOWN boolean, not
# on the token value — with in-cluster Forgejo the token is a generated password
# (unknown at plan), which would make `count` un-plannable.
resource "kubernetes_secret" "repo" {
  count = var.create_repo_secret ? 1 : 0

  metadata {
    name      = "${var.name}-gitops-repo"
    namespace = kubernetes_namespace.this.metadata[0].name
    labels = merge(var.common_labels, {
      "argocd.argoproj.io/secret-type" = "repository"
    })
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = var.git_username
    password = var.git_token
    # Send basic-auth preemptively (required by Forgejo/Gitea over HTTP) and skip
    # TLS verification for the in-cluster http(s) endpoint.
    forceHttpBasicAuth = "true"
    insecure           = tostring(startswith(var.gitops_repo_url, "http://"))
  }

  depends_on = [helm_release.this]
}

resource "kubectl_manifest" "project" {
  for_each = local.projects

  yaml_body = yamlencode({
    apiVersion = local.argocd_api_version
    kind       = "AppProject"
    metadata = {
      name       = each.key
      namespace  = kubernetes_namespace.this.metadata[0].name
      labels     = var.common_labels
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      description = each.value.description
      # The GitOps repo (in-repo charts/paths + $values) PLUS the pinned upstream
      # Helm chart repos the platform apps pull from. Explicit allow-list — not
      # "*" — so a typo'd/malicious source repo cannot be reconciled.
      sourceRepos                = concat([var.gitops_repo_url], var.additional_source_repos)
      destinations               = each.value.destinations
      clusterResourceWhitelist   = each.value.cluster_resources
      namespaceResourceWhitelist = each.value.namespace_resources
    }
  })

  depends_on = [helm_release.this]
}

# The single seed Application. It renders the in-repo bootstrap Helm chart, which
# in turn emits one ApplicationSet per platform component (the app-of-apps root).
resource "kubectl_manifest" "root" {
  yaml_body = yamlencode({
    apiVersion = local.argocd_api_version
    kind       = "Application"
    metadata = {
      name       = "root"
      namespace  = kubernetes_namespace.this.metadata[0].name
      labels     = var.common_labels
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "platform"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_revision
        path           = var.bootstrap_path
        # valuesObject injects live per-env overrides into the single bootstrap
        # values.yaml via the root Application (requires ArgoCD >= 2.6) — there
        # are no per-env values files any more:
        #   - environment: selects each app's gitops/config/<name>/<env>.yaml overlay
        #   - profile: full|tiny (tiny skips heavy apps for small hosts)
        #   - git.repoURL/targetRevision: override the source so CHILD apps
        #     reconcile from the effective repo (Forgejo in the sandbox). The git
        #     key is omitted when no override is set (a null would serialize badly).
        helm = {
          valuesObject = merge(
            {
              environment = var.environment
              profile     = var.profile
            },
            var.git_repo_url_override == "" ? {} : {
              git = {
                repoURL        = var.git_repo_url_override
                targetRevision = var.gitops_revision
              }
            }
          )
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
        retry = {
          limit = 5
          backoff = {
            duration    = "10s"
            factor      = 2
            maxDuration = "5m"
          }
        }
      }
    }
  })

  depends_on = [kubectl_manifest.project]
}
