/*
GKE module: provisions a private GKE cluster with two node pools.

  control-pool   — runs the sandbox-operator and Redis; standard COS nodes.
  execution-pool — runs gVisor sandbox pods; COS_CONTAINERD with sandbox_config.

gVisor on GKE is enabled via sandbox_config { sandbox_type = "gvisor" } on
the node pool. GKE installs and configures runsc automatically; no DaemonSet
installer is required (unlike EKS/AKS).
*/

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.20"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.20"
    }
  }
}

# ── VPC (optional — uses existing network if provided) ────────────────────────
data "google_compute_network" "network" {
  name    = var.network
  project = var.project_id
}

data "google_compute_subnetwork" "subnetwork" {
  name    = var.subnetwork
  region  = var.region
  project = var.project_id
}

# ── GKE Cluster ───────────────────────────────────────────────────────────────
resource "google_container_cluster" "sandbox" {
  provider = google-beta

  name     = var.cluster_name
  location = var.region
  project  = var.project_id

  # Remove default node pool; we manage our own.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = data.google_compute_network.network.self_link
  subnetwork = data.google_compute_subnetwork.subnetwork.self_link

  # Workload Identity — required for Autopilot and recommended for Standard.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Shielded nodes — protect against boot-level compromises.
  enable_shielded_nodes = true

  # Private cluster — nodes have no public IPs.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_ipv4_cidr_block  = "/16"
    services_ipv4_cidr_block = "/22"
  }

  # Network policy (Calico) — required for NetworkPolicy objects to be enforced.
  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
  }

  # Binary Authorization — optional, tighten in production.
  binary_authorization {
    evaluation_mode = "DISABLED"
  }

  release_channel {
    channel = "REGULAR"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T04:00:00Z"
      end_time   = "2024-01-01T08:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA"
    }
  }
}

# ── Control-plane Node Pool ────────────────────────────────────────────────────
resource "google_container_node_pool" "control" {
  name     = "control-pool"
  cluster  = google_container_cluster.sandbox.name
  location = var.region
  project  = var.project_id

  autoscaling {
    min_node_count = var.control_pool_min_nodes
    max_node_count = var.control_pool_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.control_pool_machine_type
    disk_type    = "pd-ssd"
    disk_size_gb = 50
    image_type   = "COS_CONTAINERD"

    # Label identifies control-plane nodes for operator scheduling.
    labels = {
      "sandbox.k8s.io/role" = "control"
    }

    # Taint prevents non-control workloads from landing here.
    taint {
      key    = "sandbox.k8s.io/control"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── Execution-plane Node Pool (gVisor) ─────────────────────────────────────────
resource "google_container_node_pool" "execution" {
  provider = google-beta

  name     = "execution-pool"
  cluster  = google_container_cluster.sandbox.name
  location = var.region
  project  = var.project_id

  autoscaling {
    # Scale to zero when no sandbox jobs are queued.
    min_node_count = var.execution_pool_min_nodes
    max_node_count = var.execution_pool_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.execution_pool_machine_type
    disk_type    = "pd-ssd"
    disk_size_gb = 100
    # COS_CONTAINERD is required for GKE Sandbox (gVisor).
    image_type = "COS_CONTAINERD"

    # ── gVisor enabled here ──────────────────────────────────────────────────
    # GKE installs runsc and configures containerd automatically.
    sandbox_config {
      sandbox_type = "gvisor"
    }

    labels = {
      "sandbox.k8s.io/role"   = "execution"
      "sandbox.k8s.io/gvisor" = "true"
    }

    # Taint execution nodes — only pods with the matching toleration land here.
    taint {
      key    = "sandbox.k8s.io/execution"
      value  = "true"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = google_container_cluster.sandbox.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.sandbox.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.sandbox.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "cluster_token" {
  value     = data.google_client_config.default.access_token
  sensitive = true
}

data "google_client_config" "default" {}
