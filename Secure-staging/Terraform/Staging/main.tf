terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "GCP project containing the D0/D1 data platform."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources."
  type        = string
  default     = "asia-south2"
}

variable "raw_bucket_name" {
  description = "Globally unique name for the D0 raw landing bucket."
  type        = string
}

variable "dataset_id" {
  description = "BigQuery dataset ID for D1 staged/enforced data."
  type        = string
  default     = "d1_staged_enforced"
}

variable "kms_key_name" {
  description = "Full resource name of the CMEK CryptoKey used by D0."
  type        = string
}

variable "raw_writer_principal" {
  description = "Principal allowed to write objects to D0."
  type        = string
}

variable "raw_reader_principal" {
  description = "Principal allowed to read objects from D0."
  type        = string
}

variable "analyst_group" {
  description = "Google Group granted controlled access to D1."
  type        = string
}

variable "trusted_vpc_project" {
  description = "Project containing the trusted VPC used by the IAM condition."
  type        = string
}

# ---------------------------------------------------------------------------
# Required APIs
# ---------------------------------------------------------------------------

resource "google_project_service" "storage" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "bigquery" {
  project            = var.project_id
  service            = "bigquery.googleapis.com"
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# D0 - Raw Landing Bucket
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "d0_raw_landing" {
  name                        = var.raw_bucket_name
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true

  # Prevent accidental public exposure.
  public_access_prevention = "enforced"

  # Keep object history so accidental overwrites/deletes can be recovered.
  versioning {
    enabled = true
  }

  # Require objects to remain in the raw landing zone for seven days.
  retention_policy {
    retention_period = 604800
  }

  # Prevent the bucket from being destroyed while it contains data.
  lifecycle {
    prevent_destroy = true
  }

  # CMEK encryption.
  encryption {
    default_kms_key_name = var.kms_key_name
  }

  # Automatically clean up incomplete multipart uploads.
  lifecycle_rule {
    condition {
      age = 1
    }

    action {
      type = "Delete"
    }
  }

  depends_on = [
    google_project_service.storage
  ]
}

# ---------------------------------------------------------------------------
# D0 IAM - Writer
# ---------------------------------------------------------------------------

resource "google_storage_bucket_iam_member" "d0_writer" {
  bucket = google_storage_bucket.d0_raw_landing.name
  role   = "roles/storage.objectCreator"
  member = var.raw_writer_principal

  condition {
    title       = "D0 ingestion write-only window"
    description = "Permit ingestion only from the trusted environment."
    expression = <<-EOT
      resource.name.startsWith(
        "projects/_/buckets/${google_storage_bucket.d0_raw_landing.name}/objects/"
      )
      &&
      request.time < timestamp("2030-01-01T00:00:00Z")
    EOT
  }
}

# ---------------------------------------------------------------------------
# D0 IAM - Reader
# ---------------------------------------------------------------------------

resource "google_storage_bucket_iam_member" "d0_reader" {
  bucket = google_storage_bucket.d0_raw_landing.name
  role   = "roles/storage.objectViewer"
  member = var.raw_reader_principal

  condition {
    title       = "D0 read from trusted project"
    description = "Restrict raw-data reads to the trusted GCP project."
    expression = <<-EOT
      resource.name.startsWith(
        "projects/_/buckets/${google_storage_bucket.d0_raw_landing.name}/objects/"
      )
      &&
      resource.matchTag(
        "${var.trusted_vpc_project}/environment",
        "staging"
      )
    EOT
  }
}

# ---------------------------------------------------------------------------
# D1 - BigQuery Staged / Enforced Dataset
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "d1_staged_enforced" {
  project    = var.project_id
  dataset_id = var.dataset_id
  location   = var.region

  description = "D1 staged/enforced data with row-level security."

  # Do not make datasets publicly discoverable through IAM.
  access {
    role          = "READER"
    group_by_email = var.analyst_group
  }

  # Dataset-level deletion protection.
  delete_contents_on_destroy = false

  depends_on = [
    google_project_service.bigquery
  ]
}

# ---------------------------------------------------------------------------
# Example D1 table
#
# In production, replace this schema with the actual enforced schema.
# ---------------------------------------------------------------------------

resource "google_bigquery_table" "customer_data" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.d1_staged_enforced.dataset_id
  table_id   = "customer_data"

  deletion_protection = true

  schema = jsonencode([
    {
      name = "customer_id"
      type = "STRING"
      mode = "REQUIRED"
    },
    {
      name = "tenant_id"
      type = "STRING"
      mode = "REQUIRED"
    },
    {
      name = "customer_name"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "email"
      type = "STRING"
      mode = "NULLABLE"
    },
    {
      name = "classification"
      type = "STRING"
      mode = "REQUIRED"
    }
  ])

  depends_on = [
    google_bigquery_dataset.d1_staged_enforced
  ]
}

# ---------------------------------------------------------------------------
# D1 Row-Level Security
#
# Only rows belonging to the analyst's permitted tenant are visible.
#
# SESSION_USER() is used so the policy evaluates the authenticated
# BigQuery identity at query time.
# ---------------------------------------------------------------------------

resource "google_bigquery_row_access_policy" "customer_tenant_policy" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.d1_staged_enforced.dataset_id
  table_id   = google_bigquery_table.customer_data.table_id

  policy_id = "tenant-isolation"

  filter_expression = <<-SQL
    tenant_id = SESSION_USER()
  SQL

  grantee {
    group_by_email = var.analyst_group
  }
}

# ---------------------------------------------------------------------------
# D1 IAM
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset_iam_member" "d1_data_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.d1_staged_enforced.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "group:${var.analyst_group}"

  condition {
    title       = "D1 staged-data access"
    description = "Limit access to the staging dataset during the approved period."
    expression = <<-EOT
      request.time >= timestamp("2026-01-01T00:00:00Z")
      &&
      request.time < timestamp("2030-01-01T00:00:00Z")
    EOT
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "d0_raw_bucket" {
  description = "D0 raw landing bucket."
  value       = google_storage_bucket.d0_raw_landing.name
}

output "d1_dataset" {
  description = "D1 staged/enforced BigQuery dataset."
  value       = google_bigquery_dataset.d1_staged_enforced.dataset_id
}

output "d1_customer_table" {
  description = "Example D1 enforced table."
  value       = google_bigquery_table.customer_data.table_id
}
