resource "kubernetes_namespace" "this" {
  metadata {
    name   = var.namespace
    labels = var.common_labels
  }
}

# Admin credential for the sandbox git server. Generated (not hardcoded) and
# surfaced as a sensitive output so callers can seed the repo.
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "-_.~"
}

resource "helm_release" "this" {
  name       = "forgejo"
  namespace  = kubernetes_namespace.this.metadata[0].name
  repository = "oci://code.forgejo.org/forgejo-helm"
  chart      = "forgejo"
  version    = var.chart_version

  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    replicaCount = 1

    # Single-node sandbox: sqlite + no external cache/DB dependencies.
    "redis-cluster"  = { enabled = false }
    "postgresql"     = { enabled = false }
    "postgresql-ha"  = { enabled = false }
    "valkey-cluster" = { enabled = false }
    "valkey"         = { enabled = false }

    persistence = {
      enabled      = true
      size         = var.storage_size
      storageClass = "local-path"
    }

    service = {
      http = { type = "ClusterIP", port = 3000 }
      ssh  = { type = "ClusterIP", port = 22 }
    }

    ingress = {
      enabled          = true
      ingressClassName = "traefik"
      # Auto-discovered tile on the platform portal (gitops/config/portal).
      annotations = {
        "gethomepage.dev/enabled"     = "true"
        "gethomepage.dev/name"        = "Forgejo"
        "gethomepage.dev/group"       = "Platform"
        "gethomepage.dev/icon"        = "forgejo.png"
        "gethomepage.dev/description" = "Git + CI (GitOps source)"
      }
      hosts = [{
        host  = var.ingress_host
        paths = [{ path = "/", pathType = "Prefix" }]
      }]
    }

    gitea = {
      admin = {
        username = var.admin_username
        password = random_password.admin.result
        email    = "${var.admin_username}@local.platform"
      }
      config = {
        database = { DB_TYPE = "sqlite3" }
        server = {
          ROOT_URL     = "http://${local.http_service}.${var.namespace}.svc:3000/"
          OFFLINE_MODE = true
          LANDING_PAGE = "explore"
          DISABLE_SSH  = true
        }
        service = {
          DISABLE_REGISTRATION = true
        }
        # Forgejo Actions on: the in-cluster runner (gitops/config/forgejo-runner)
        # registers here and executes CI. Actions are pulled from GitHub's registry
        # (actions/checkout@v4, etc.) so the workflows are portable.
        actions = {
          ENABLED             = true
          DEFAULT_ACTIONS_URL = "github"
        }
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "192Mi" }
      limits   = { cpu = "1", memory = "512Mi" }
    }
  })]
}
