variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "location" {
  description = "BigQuery & GCS multi-region or region (e.g., US)"
  type        = string
  default     = "US"
}

variable "region" {
  description = "Default Google provider region"
  type        = string
  default     = "us-central1"
}

variable "gcs_bucket_name" {
  description = "Globally unique GCS bucket name for sample product images"
  type        = string
}

variable "gcs_image_prefix" {
  description = "Folder prefix inside the GCS bucket for sample product images"
  type        = string
  default     = "product_listings/images"
}

variable "bq_dataset" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "bq_objectref_demo"
}

variable "bq_connection_id" {
  description = "BigQuery Cloud Resource Connection ID"
  type        = string
  default     = "bq_objectref_demo_gcs_conn"
}
