-- =============================================================================
-- STEP 1: Spontaneous GCS Discovery with OBJ.LIST() (No External Object Table!)
-- =============================================================================
-- Before ObjectRef & OBJ.LIST reached GA, inspecting unstructured images in GCS
-- required running DDL (`CREATE EXTERNAL TABLE ... WITH CONNECTION ...`) first.
--
-- With OBJ.LIST(), you can query any GCS URI wildcard on the fly. Every row
-- returned includes a pre-built `ref` column of type `ObjectRef`:
--   STRUCT<uri STRING, version STRING, authorizer STRING, details JSON>
-- =============================================================================

SELECT
  uri,
  content_type,
  size AS size_bytes,
  updated,
  md5_hash,
  ref AS object_ref_struct
FROM
  OBJ.LIST(
    'gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/*',
    '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}'
  )
ORDER BY
  uri;
