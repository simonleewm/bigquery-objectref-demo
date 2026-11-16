terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. Enable required Google Cloud APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "bigquery.googleapis.com",
    "bigqueryconnection.googleapis.com",
    "aiplatform.googleapis.com",
    "storage.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# 2. Cloud Storage bucket for unstructured product listing images
resource "google_storage_bucket" "image_bucket" {
  name                        = var.gcs_bucket_name
  project                     = var.project_id
  location                    = var.location
  uniform_bucket_level_access = true
  force_destroy               = true

  depends_on = [google_project_service.apis]
}

# 3. Upload the 7 sample product images from ../sample_images/
resource "google_storage_bucket_object" "sample_images" {
  for_each     = fileset("${path.module}/../sample_images", "*")
  name         = "${var.gcs_image_prefix}/${each.value}"
  bucket       = google_storage_bucket.image_bucket.name
  source       = "${path.module}/../sample_images/${each.value}"
  content_type = endswith(each.value, ".png") ? "image/png" : "image/jpeg"
}

# 4. BigQuery Dataset
resource "google_bigquery_dataset" "demo_dataset" {
  dataset_id                 = var.bq_dataset
  project                    = var.project_id
  location                   = var.location
  delete_contents_on_destroy = true

  depends_on = [google_project_service.apis]
}

# 5. BigQuery Cloud Resource Connection (used as ObjectRef authorizer & Vertex AI bridge)
resource "google_bigquery_connection" "objref_connection" {
  connection_id = var.bq_connection_id
  project       = var.project_id
  location      = var.location
  friendly_name = "ObjectRef GCS and Vertex AI Connection"
  description   = "Authorizer connection for BigQuery ObjectRef, OBJ.LIST, and AI functions"

  cloud_resource {}

  depends_on = [google_project_service.apis]
}

# 6. Grant the Connection Service Account read access to the GCS Bucket
resource "google_storage_bucket_iam_member" "conn_gcs_viewer" {
  bucket = google_storage_bucket.image_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_bigquery_connection.objref_connection.cloud_resource[0].service_account_id}"
}

# 7. Grant the Connection Service Account Vertex AI User role for AI.IF / AI.CLASSIFY / AI.GENERATE
resource "google_project_iam_member" "conn_vertex_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_bigquery_connection.objref_connection.cloud_resource[0].service_account_id}"
}
