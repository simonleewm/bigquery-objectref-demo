-- =============================================================================
-- STEP 4: Multimodal Listing Auditor with ObjectRef + AI.IF + AI.CLASSIFY
--         + AI.GENERATE Combined with BigQuery Pipe Syntax (|>)
-- =============================================================================
-- Here we combine three recent Google Cloud Data Engineering announcements:
--   1. `ObjectRef` columns passed directly into multimodal AI functions
--   2. Managed Semantic SQL:
--      • `AI.IF`       -> Detects promotional text overlays / spam watermarks
--      • `AI.CLASSIFY` -> Classifies the visual product category from the photo
--      • `AI.GENERATE` -> Extracts structured visual color & item description
--   3. GoogleSQL Pipe Syntax (`|>`) for readable top-to-bottom transformation
-- =============================================================================

CREATE OR REPLACE TABLE `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_audited` AS
FROM `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_tech_checked`
|> EXTEND
     -- 1. Semantic Watermark Check via AI.IF (catches SKU-1003's "50% OFF MEGA SALE" banner)
     AI.IF(
       (
         'Does this product photo contain promotional text overlays, discount sale banners, or phone number watermarks?',
         primary_image_ref
       ),
       connection_id => '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}',
       endpoint => '${GEMINI_ENDPOINT}'
     ) AS has_watermark_violation,

     -- 2. Visual Category Classification via AI.CLASSIFY (catches SKU-1005's cat photo!)
     AI.CLASSIFY(
       primary_image_ref,
       categories => ['Footwear', 'Bags', 'Kitchen', 'Watches', 'Electronics', 'Pet / Animal / Other'],
       connection_id => '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}',
       endpoint => '${GEMINI_ENDPOINT}'
     ) AS detected_category,

     -- 3. Structured Visual Attribute Extraction via AI.GENERATE (catches SKU-1002's Blue vs Black mismatch!)
     AI.GENERATE(
       (
         'Identify the primary color of the main subject in this photo (choose one word such as Red, Blue, Black, White, Silver, or Orange) and provide a short 1-sentence visual description.',
         primary_image_ref
       ),
       output_schema => '''
         detected_color STRING,
         visual_description STRING
       ''',
       connection_id => '${GCP_PROJECT_ID}.${GCP_LOCATION}.${BQ_CONNECTION_ID}',
       endpoint => '${GEMINI_ENDPOINT}'
     ) AS visual_attributes
|> SELECT
     sku_id,
     listed_title,
     CONCAT(CAST(image_tech_check.width AS STRING), 'x', CAST(image_tech_check.height AS STRING)) AS dimensions_px,
     image_tech_check.is_high_res,
     listed_category,
     detected_category,
     listed_color,
     visual_attributes.detected_color AS photo_detected_color,
     has_watermark_violation,
     ARRAY_LENGTH(gallery_image_refs) AS gallery_count,
     visual_attributes.visual_description,
     -- Automated Listing Audit Decision Engine
     CASE
       WHEN NOT image_tech_check.is_high_res
         THEN 'REJECTED: Low Resolution (< 500x500 px) — Caught by Python UDF ($0 LLM Cost)'
       WHEN has_watermark_violation
         THEN 'REJECTED: Promotional Watermark / Text Overlay Violation'
       WHEN LOWER(listed_category) != LOWER(detected_category)
         THEN CONCAT('REJECTED: Wrong Item Uploaded (Listed ', listed_category, ' vs Photo ', detected_category, ')')
       WHEN LOWER(listed_color) != LOWER(TRIM(visual_attributes.detected_color))
         THEN CONCAT('FLAGGED: Color Mismatch (Listed ', listed_color, ' vs Photo ', visual_attributes.detected_color, ')')
       ELSE 'APPROVED: Clean Photo Matches Listing Metadata'
     END AS audit_decision;

-- Display the final audit results across all 6 SKUs
SELECT
  sku_id,
  listed_title,
  dimensions_px,
  listed_category,
  detected_category,
  listed_color,
  photo_detected_color,
  has_watermark_violation,
  audit_decision
FROM
  `${GCP_PROJECT_ID}.${BQ_DATASET}.product_listings_audited`
ORDER BY
  sku_id;
