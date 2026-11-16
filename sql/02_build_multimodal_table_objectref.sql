-- =============================================================================
-- STEP 2: Build a Native Multimodal Table with OBJ.MAKE_REF & OBJ.FETCH_METADATA
-- =============================================================================
-- Unlike legacy External Object Tables (which isolated files in a separate
-- 1-file-per-row external table), `ObjectRef` is a first-class data type.
--
-- Here we transform the raw CSV staging table (`product_listings_staging`) into
-- a native BigQuery table (`product_listings_multimodal`) that stores:
--   1. Standard relational columns (`sku_id`, `listed_color`, `listed_category`)
--   2. A single `ObjectRef` column (`primary_image_ref`) for the main photo
--   3. An `ARRAY<ObjectRef>` column (`gallery_image_refs`) holding 1..N product
--      photos on the exact same row (see SKU-1006 which has 2 laptop angles).
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_multimodal` AS
SELECT
  s.sku_id,
  s.seller_id,
  s.listed_title,
  s.listed_category,
  s.listed_color,
  CAST(s.listed_price AS NUMERIC) AS listed_price,

  -- 1. Single ObjectRef column: construct pointer with OBJ.MAKE_REF and hydrate
  --    GCS metadata (size, content_type, md5, updated) via OBJ.FETCH_METADATA
  OBJ.FETCH_METADATA(
    OBJ.MAKE_REF(
      CONCAT('gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/', s.primary_image),
      '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}'
    )
  ) AS primary_image_ref,

  -- 2. ARRAY<ObjectRef> column: store multiple gallery photos per product row!
  OBJ.FETCH_METADATA(
    ARRAY(
      SELECT
        OBJ.MAKE_REF(
          CONCAT('gs://${GCS_BUCKET_NAME}/${GCS_IMAGE_PREFIX}/', TRIM(img_file)),
          '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}'
        )
      FROM UNNEST(SPLIT(s.gallery_images, '|')) AS img_file
    )
  ) AS gallery_image_refs

FROM
  `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_staging` AS s;

-- Verify the hydrated ObjectRef metadata stored right alongside relational columns
SELECT
  sku_id,
  listed_title,
  listed_category,
  listed_color,
  primary_image_ref.uri AS primary_photo_uri,
  INT64(primary_image_ref.details.gcs_metadata.size) AS file_size_bytes,
  STRING(primary_image_ref.details.gcs_metadata.content_type) AS content_type,
  ARRAY_LENGTH(gallery_image_refs) AS gallery_photo_count
FROM
  `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_multimodal`
ORDER BY
  sku_id;
