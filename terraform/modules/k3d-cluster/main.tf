# Provision (or adopt) this environment's k3s cluster as a set of Docker
# containers via k3d. The cluster is created BY Terraform (metal/k3s reference,
# adapted to k3d) — no external setup script. Traefik + klipper-lb ship with
# k3s; the loadbalancer port maps make *.127.0.0.1.sslip.io reachable from the host.
resource "null_resource" "cluster" {
  triggers = {
    name       = var.cluster_name
    servers    = var.servers
    agents     = var.agents
    http_port  = var.http_port
    https_port = var.https_port
    k3s_image  = var.k3s_image
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      # Shared registry (created once, reused across clusters). Images pushed here
      # are pulled by k3s reliably — replaces the flaky `k3d image import`.
      if ! k3d registry list 2>/dev/null | grep -q "k3d-${var.registry_name}"; then
        echo "creating k3d registry 'k3d-${var.registry_name}' on :${var.registry_port}"
        k3d registry create "${var.registry_name}" --port "0.0.0.0:${var.registry_port}"
      fi
      if k3d cluster list "${var.cluster_name}" >/dev/null 2>&1; then
        echo "k3d cluster '${var.cluster_name}' already exists — reusing"
      else
        echo "creating k3d cluster '${var.cluster_name}' (${var.servers} server / ${var.agents} agent)"
        k3d cluster create "${var.cluster_name}" \
          --image "${var.k3s_image}" \
          --servers "${var.servers}" \
          --agents "${var.agents}" \
          -p "${var.http_port}:80@loadbalancer" \
          -p "${var.https_port}:443@loadbalancer" \
          --registry-use "k3d-${var.registry_name}:${var.registry_port}" \
          ${local.api_port_arg} ${local.tls_san_args} \
          --wait --timeout "${var.wait_timeout}"
      fi
      kubectl config use-context "${local.kube_context}" >/dev/null
      # With --api-port 0.0.0.0:<port>, k3d writes the kubeconfig server as
      # https://0.0.0.0:<port>. Binding on 0.0.0.0 is what we want (remote access
      # via the host's LAN IP), but 0.0.0.0 as a client DESTINATION is unreliable
      # on macOS/colima — every API call times out and retries (i/o + TLS
      # handshake timeouts), which e.g. makes the services-layer Vault ingress calls take
      # >30s and fail. Point the LOCAL kubeconfig at 127.0.0.1 (fast + reliable
      # everywhere; the server cert includes 127.0.0.1). Remote clients use the
      # LAN IP added via tls_sans with their own kubeconfig.
      %{if var.api_port > 0~}
      kubectl config set-cluster "${local.kube_context}" --server="https://127.0.0.1:${var.api_port}" >/dev/null 2>&1 || true
      %{endif~}
      echo "waiting for node(s) to be Ready"
      kubectl wait --for=condition=Ready nodes --all --timeout="${var.wait_timeout}"
    EOT
  }

  # Tearing down an environment deletes its whole cluster (fast, clean reset).
  # Inline: destroy provisioners may only reference self.*.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = "k3d cluster delete '${self.triggers.name}' || true"
  }
}
