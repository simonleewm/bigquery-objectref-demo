output "gcs_image_uri_pattern" {
  description = "GCS wildcard URI for OBJ.LIST()"
  value       = "gs://${google_storage_bucket.image_bucket.name}/${var.gcs_image_prefix}/*"
}

output "bq_authorizer_connection" {
  description = "Fully qualified BigQuery connection ID for ObjectRef authorizer"
  value       = "${var.project_id}.${var.location}.${google_bigquery_connection.objref_connection.connection_id}"
}

output "connection_service_account" {
  description = "Service Account email generated for the BigQuery Cloud Resource Connection"
  value       = google_bigquery_connection.objref_connection.cloud_resource[0].service_account_id
}
